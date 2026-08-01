var _g  # Global reference
const PREVIEW_SCAN_INTERVAL = 0.5  # seconds between preview-container discovery scans
const DEFAULT_PREVIEW_PERCENT := 15
const MIN_PREVIEW_PERCENT := 5
const MAX_PREVIEW_PERCENT := 100
const TEXTURE_CACHE_LIMIT = 128  # safety cap on the resized-preview cache


var _last_tool_name = ""
var _preview_nodes = []
var _was_focused = true
var _mouse_watcher = null
var _had_selection = false  # tracks whether SelectTool had objects selected
var _scan_accum = 0.0

# Event-driven resize state.
# _entries: cached {container, tex_rect} pairs found by the throttled discovery
#   scan. Enforcement then runs every frame on this short list only, which is
#   what removes the flicker: DD re-assigns the original (big) texture on every
#   mouse move over the asset grid, and we swap the resized one back in the
#   same frame, before rendering.
# _texture_cache: original-texture instance id -> {"original": Texture (kept
#   alive so the id stays stable), "patched": ImageTexture or null (null means
#   the texture already fits on screen)}.
# _applied: tex_rect instance id -> original texture currently swapped out
#   (used to restore everything when the percent setting changes).
var _entries = []
var _texture_cache = {}
var _applied = {}
var _last_max_h: int = -1
# Set by the SceneTree "node_added" hook whenever a preview-looking node is
# created, so discovery happens on the very next update() instead of waiting
# for the throttled scan tick.
var _needs_rescan: bool = false

# Configurable max preview height as % of screen height (loaded from disk).
var _max_preview_percent: int = DEFAULT_PREVIEW_PERCENT
var _prefs_hooked: bool = false
var _preview_slider = null
var _preview_spinbox = null
var _save_pending_frames: int = 0


func _settings_path() -> String:
	return "user://UnofficialPatch/PreviewFix/settings.json"


func _load_settings():
	var f = File.new()
	if f.open(_settings_path(), File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error == OK and parsed.result is Dictionary:
		var d = parsed.result
		if d.has("max_preview_percent"):
			var v = int(d["max_preview_percent"])
			if v < MIN_PREVIEW_PERCENT: v = MIN_PREVIEW_PERCENT
			if v > MAX_PREVIEW_PERCENT: v = MAX_PREVIEW_PERCENT
			_max_preview_percent = v


func _save_settings():
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch/PreviewFix"):
		dir.make_dir_recursive("user://UnofficialPatch/PreviewFix")
	var f = File.new()
	if f.open(_settings_path(), File.WRITE) == OK:
		f.store_string(JSON.print({"max_preview_percent": _max_preview_percent}, "\t"))
		f.close()


func _try_hook_preferences() -> void:
	# Inject "Max Preview Size" slider into Preferences > Interface tab.
	# Re-attempted every frame from update() until the Preferences node exists.
	if _prefs_hooked: return
	if not _g.Editor or not is_instance_valid(_g.Editor): return
	var prefs = _g.Editor.get_node_or_null("Windows/Preferences")
	if prefs == null: return
	var interface_vbox = prefs.get_node_or_null("Margins/VAlign/Interface")
	if interface_vbox == null: return
	# Avoid double-injection
	if interface_vbox.get_node_or_null("PreviewFixSizeRow") != null:
		_prefs_hooked = true
		return
	var row = HBoxContainer.new()
	row.name = "PreviewFixSizeRow"
	var lbl = Label.new()
	lbl.text = "Max Preview Size"
	# Match popup_blur's label width so the sliders align vertically in the
	# Interface tab. The "%" suffix on the SpinBox conveys the unit.
	lbl.rect_min_size = Vector2(170, 0)
	row.add_child(lbl)
	_preview_slider = HSlider.new()
	_preview_slider.min_value = MIN_PREVIEW_PERCENT
	_preview_slider.max_value = MAX_PREVIEW_PERCENT
	_preview_slider.step = 1
	_preview_slider.value = _max_preview_percent
	_preview_slider.rect_min_size = Vector2(150, 20)
	_preview_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_preview_slider.connect("value_changed", self, "_on_preview_slider")
	row.add_child(_preview_slider)
	_preview_spinbox = SpinBox.new()
	_preview_spinbox.min_value = MIN_PREVIEW_PERCENT
	_preview_spinbox.max_value = MAX_PREVIEW_PERCENT
	_preview_spinbox.step = 1
	_preview_spinbox.value = _max_preview_percent
	_preview_spinbox.suffix = "%"
	_preview_spinbox.rect_min_size = Vector2(70, 0)
	_preview_spinbox.connect("value_changed", self, "_on_preview_spinbox")
	row.add_child(_preview_spinbox)
	# Reset button
	var reset_btn = Button.new()
	reset_btn.text = "Reset"
	reset_btn.connect("pressed", self, "_on_preview_reset")
	row.add_child(reset_btn)
	interface_vbox.add_child(row)
	_prefs_hooked = true
	print("[PreviewFix] Max preview size slider injected in Preferences (value=", _max_preview_percent, "%)")


func _on_preview_slider(value: float) -> void:
	if _preview_spinbox != null and _preview_spinbox.value != value:
		_preview_spinbox.value = value
	_apply_preview_percent(int(value))


func _on_preview_spinbox(value: float) -> void:
	if _preview_slider != null and _preview_slider.value != value:
		_preview_slider.value = value
	_apply_preview_percent(int(value))


func _on_preview_reset() -> void:
	if _preview_slider != null: _preview_slider.value = DEFAULT_PREVIEW_PERCENT
	if _preview_spinbox != null: _preview_spinbox.value = DEFAULT_PREVIEW_PERCENT
	_apply_preview_percent(DEFAULT_PREVIEW_PERCENT)


func _apply_preview_percent(pct: int) -> void:
	if pct < MIN_PREVIEW_PERCENT: pct = MIN_PREVIEW_PERCENT
	if pct > MAX_PREVIEW_PERCENT: pct = MAX_PREVIEW_PERCENT
	if pct == _max_preview_percent: return
	_max_preview_percent = pct
	# Drop the patched-texture cache so currently-open previews re-resize
	# at the new ratio on the next scan tick. Restore originals first so we
	# don't try to re-patch an already-patched texture.
	_invalidate_patched_textures()
	# Debounce save: don't write to disk on every slider tick.
	_save_pending_frames = 30


func _invalidate_patched_textures() -> void:
	# Restore the original texture on every TextureRect we patched, then drop
	# both caches so previews get rebuilt at the new ratio on the next frame.
	for nid in _applied.keys():
		var obj = instance_from_id(nid)
		if obj != null and is_instance_valid(obj) and obj is TextureRect:
			var cur = obj.texture
			if cur != null and cur.has_meta("preview_fix_patched"):
				obj.texture = _applied[nid]
	_applied.clear()
	_texture_cache.clear()


func initialize():
	_load_settings()
	# Create a Node that watches for mouse exit notification
	var script_src = """
extends Node

var preview_fix = null

func _notification(what):
	if what == MainLoop.NOTIFICATION_WM_MOUSE_EXIT:
		if preview_fix != null:
			preview_fix._on_mouse_exit_window()
	if what == MainLoop.NOTIFICATION_WM_MOUSE_ENTER:
		if preview_fix != null:
			preview_fix._on_mouse_enter_window()
"""
	var script = GDScript.new()
	script.source_code = script_src
	script.reload()
	_mouse_watcher = Node.new()
	_mouse_watcher.set_script(script)
	_mouse_watcher.preview_fix = self
	_mouse_watcher.name = "PreviewFixWatcher"
	_g.Editor.add_child(_mouse_watcher)
	# React instantly when DD creates preview nodes on the fly: any node whose
	# name mentions "preview" triggers a rescan on the next update() frame.
	# The callback itself only does a cheap name check, so the per-node cost
	# during map loads stays negligible.
	_g.Editor.get_tree().connect("node_added", self, "_on_node_added")
	print("[PreviewFix] Initialized with mouse watcher (max=", _max_preview_percent, "%)")


func _on_node_added(node) -> void:
	if _needs_rescan: return
	if node == null: return
	if "preview" in node.name.to_lower():
		_needs_rescan = true

func _find_all_preview_containers(node, result):
	if node == null or not is_instance_valid(node): return
	if "preview" in node.name.to_lower() and node is PanelContainer:
		result.append(node)
	for child in node.get_children():
		_find_all_preview_containers(child, result)


func _find_child_texture_rect(node):
	if node is TextureRect: return node
	for child in node.get_children():
		var r = _find_child_texture_rect(child)
		if r != null: return r
	return null


func _rescan_preview_entries() -> void:
	# DD exposes its single PreviewContainer directly on the editor
	# (PreviewContainer._EnterTree does Master.Editor.Preview = this), so no
	# tree walk is needed in the normal case. The recursive scan of the Editor
	# UI subtree is kept only as a fallback.
	_entries.clear()
	if _g.Editor == null or not is_instance_valid(_g.Editor): return
	var preview = _g.Editor.get("Preview")
	if preview != null and is_instance_valid(preview):
		_entries.append({"container": preview, "tex_rect": _find_child_texture_rect(preview)})
		return
	var found = []
	_find_all_preview_containers(_g.Editor, found)
	for node in found:
		if not is_instance_valid(node): continue
		# tex_rect may not exist yet (DD can build the container first and add
		# the TextureRect later); it is resolved lazily in the enforce loop.
		_entries.append({"container": node, "tex_rect": _find_child_texture_rect(node)})


func _build_patched_texture(tex, max_h: int):
	# Returns a resized ImageTexture, or null if the texture already fits.
	# This (get_data + resize) is the only expensive step, and it now runs at
	# most once per asset texture — every later re-assignment by DD is undone
	# with a plain cached-texture swap.
	var th = tex.get_height()
	if th <= max_h: return null
	var tw = tex.get_width()
	var img = tex.get_data()
	if img == null: return null
	if img.is_compressed():
		img.decompress()
	var r = float(max_h) / float(th)
	var new_w = max(int(tw * r), 1)
	img.resize(new_w, max_h, Image.INTERPOLATE_BILINEAR)
	var new_tex = ImageTexture.new()
	new_tex.create_from_image(img)
	new_tex.set_meta("preview_fix_patched", true)
	return new_tex


func _enforce_preview_sizes() -> void:
	# Runs every frame on the cached entries (cheap: a few validity checks and
	# one texture identity comparison per visible preview). DD re-sets the
	# original texture on mouse motion; we swap the resized one back in the
	# same frame, so no flicker is ever rendered.
	var screen_h = OS.get_real_window_size().y
	var max_h = int(screen_h * float(_max_preview_percent) / 100.0)
	if max_h <= 0: return
	if max_h != _last_max_h:
		# Percent setting or window height changed: rebuild everything.
		if _last_max_h != -1:
			_invalidate_patched_textures()
		_last_max_h = max_h
	for e in _entries:
		var node = e["container"]
		if not is_instance_valid(node): continue
		if not node.visible: continue
		var tex_rect = e["tex_rect"]
		if tex_rect == null or not is_instance_valid(tex_rect):
			# Re-resolve inside the container only (tiny subtree walk), so a
			# TextureRect recreated by DD is picked up the same frame.
			tex_rect = _find_child_texture_rect(node)
			if tex_rect == null: continue
			e["tex_rect"] = tex_rect
		var tex = tex_rect.texture
		if tex == null: continue
		if tex.has_meta("thumbnail"):
			# DD is still showing the small thumbnail: PreviewContainer._Process
			# waits for Global.Preferences.FullPreviewDelay before swapping in
			# the full texture (Library.Seek). Drive that same method with a
			# huge delta to make the swap happen right now — this reuses DD's
			# own logic (category, ImageTextureEx cache, load flags), and the
			# resize below then applies in the same frame, before rendering.
			node.call("_Process", 3600.0)
			tex = tex_rect.texture
			if tex == null or tex.has_meta("thumbnail"): continue
		if tex.has_meta("preview_fix_patched"):
			# Already ours — just keep the container size pinned, as DD may
			# have re-applied the full-size rect on mouse move.
			var want = Vector2(tex.get_width() + 20, tex.get_height() + 50)
			if node.rect_size != want:
				node.rect_size = want
			continue
		var tid = tex.get_instance_id()
		var patched = null
		if _texture_cache.has(tid):
			patched = _texture_cache[tid]["patched"]
		else:
			patched = _build_patched_texture(tex, max_h)
			if _texture_cache.size() >= TEXTURE_CACHE_LIMIT:
				_texture_cache.clear()
			# Keep a reference to the original so its instance id stays valid
			# for the lifetime of the cache entry.
			_texture_cache[tid] = {"original": tex, "patched": patched}
		if patched == null: continue  # already fits on screen
		_applied[tex_rect.get_instance_id()] = tex
		tex_rect.texture = patched
		node.rect_size = Vector2(patched.get_width() + 20, patched.get_height() + 50)


func update(delta):
	# Inject the Preferences slider as soon as the window exists.
	_try_hook_preferences()

	# Debounced save: write to disk only after the slider has been idle
	# for ~30 frames (~500ms) of no value change.
	if _save_pending_frames > 0:
		_save_pending_frames -= 1
		if _save_pending_frames == 0:
			_save_settings()

	# Throttled recursive scan: only *discovers* preview containers. The
	# actual size enforcement below is event-cheap and runs every frame.
	_scan_accum += delta
	if _needs_rescan or _scan_accum >= PREVIEW_SCAN_INTERVAL:
		_needs_rescan = false
		_scan_accum = 0.0
		_rescan_preview_entries()

	# Per-frame enforcement on the cached entries — swaps the resized texture
	# back the moment DD re-assigns the original one, before rendering.
	_enforce_preview_sizes()

	# Detect tool change (including Escape which deselects tool)
	var current_tool = _g.Editor.ActiveToolName
	if current_tool != _last_tool_name:
		_last_tool_name = current_tool
		_hide_previews()
		# New tool panels may bring new preview containers: rescan right away.
		_rescan_preview_entries()
	
	# Detect window focus loss (handles click outside)
	var is_focused = OS.is_window_focused()
	if not is_focused:
		_hide_previews()
	if is_focused and not _was_focused:
		_hide_previews()
	_was_focused = is_focused
	
	# Detect asset deletion while preview is open:
	# if the selection just became empty, hide any visible preview.
	if current_tool == "SelectTool":
		var select_tool = _g.Editor.Tools["SelectTool"]
		var raw = select_tool.RawSelectables
		var has_selection = raw != null and raw.size() > 0
		if _had_selection and not has_selection and _has_visible_preview():
			_hide_previews()
		_had_selection = has_selection
	else:
		_had_selection = false

func _on_mouse_exit_window():
	_hide_previews()

func _on_mouse_enter_window():
	pass

func _has_visible_preview() -> bool:
	if _preview_nodes.size() == 0:
		_find_preview_nodes(_g.Editor)
	for node in _preview_nodes:
		if node != null and is_instance_valid(node) and node.visible:
			return true
	return false

func _hide_previews():
	if _preview_nodes.size() == 0:
		_find_preview_nodes(_g.Editor)
	for node in _preview_nodes:
		if node != null and is_instance_valid(node) and node.visible:
			node.visible = false

func _find_preview_nodes(root):
	_preview_nodes.clear()
	_scan_for_previews(root)

func _scan_for_previews(node):
	if node == null or not is_instance_valid(node):
		return
	var name_lower = node.name.to_lower()
	if "preview" in name_lower and (node is PopupPanel or node is Popup or node is PanelContainer or node is Panel):
		_preview_nodes.append(node)
	if node.get_class() == "ItemList" or "GridMenu" in str(node.get_class()):
		for child in node.get_children():
			if child is Popup or child is PopupPanel or child is Panel:
				if "preview" in child.name.to_lower() or child is PopupPanel:
					_preview_nodes.append(child)
	for child in node.get_children():
		_scan_for_previews(child)
