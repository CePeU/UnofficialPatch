# pack_cache_fix.gd  v8
# ------------------------------------------------------------------
# Purge stale asset packs from Dungeondraft's UI cache.
#
# Problem: when opening Map B after Map A, packs from Map A stay
# browsable in the UI even though they aren't in Map B's manifest.
# Placing those assets causes data loss on reload.
#
# Approach:
#   1. Maintain a session-scoped file of all pack IDs seen across
#      maps (user://UnofficialPatch/pack_cache_fix_known.dat), wiped on DD startup.
#   2. On map load, stale = packs in known list that are NOT in the
#      current manifest AND are still present in AssetPacks dict.
#   3. On user confirmation, erase from AssetPacks + continuously
#      remove stale items from every ItemList in the UI.
# ------------------------------------------------------------------

var _g

var _cleanup_done : bool = false
var _wait_timer : float = 0.0
const STARTUP_DELAY : float = 2.0
const PURGE_CHECK_INTERVAL : float = 0.05
# Above this many removals, rebuilding the list (O(M)) beats
# per-item remove_item calls (O(K*M) internal shifts)
const REBUILD_THRESHOLD : int = 32
const KNOWN_PACKS_FILE : String = "user://UnofficialPatch/pack_cache_fix_known.dat"

# Active purge state
var _purge_active : bool = false
var _stale_ids_dict : Dictionary = {}
var _stale_pack_names : Dictionary = {}
var _purge_queued : bool = false
var _purge_timer : float = 0.0
var _obj_menu = null
var _path_menu = null
var _in_purge : bool = false
var _all_menus : Array = []
var _terrain_pack_list = null
var _last_world_id : int = -1
const SESSION_FILE : String = "user://UnofficialPatch/pack_cache_fix_session.dat"

func initialize() -> void:
	_cleanup_done = false
	_purge_active = false
	_wait_timer = 0.0
	print("[PackCacheFix] Initialisé v5.")

func update(delta : float) -> void:
	# Detect map change via World instance
	if _g != null and "World" in _g and _g.World != null and is_instance_valid(_g.World):
		var wid = _g.World.get_instance_id()
		if wid != _last_world_id:
			_last_world_id = wid
			# Reset for new map
			_cleanup_done = false
			_purge_active = false
			_wait_timer = 0.0
			_purge_timer = 0.0
			_stale_ids_dict = {}
			_stale_pack_names = {}
			_purge_queued = false
			_all_menus = []
			_obj_menu = null
			_path_menu = null
			_terrain_pack_list = null
			_in_purge = false
			print("[PackCacheFix] Map changée — reset.")
			return

	if not _cleanup_done:
		_wait_timer += delta
		if _wait_timer < STARTUP_DELAY:
			return
		if _check_and_cleanup():
			_cleanup_done = true
		return

	if not _purge_active:
		return
	_purge_timer += delta
	if _purge_timer < PURGE_CHECK_INTERVAL:
		return
	_purge_timer = 0.0
	_check_and_repurge()

# ------------------------------------------------------------------
# Startup: detect stale packs
# ------------------------------------------------------------------
func _check_and_cleanup() -> bool:
	if _g == null or not ("Editor" in _g) or _g.Editor == null:
		return false
	if not ("Header" in _g) or _g.Header == null:
		return false

	# Current map's manifest
	var current_ids = {}
	if "AssetManifest" in _g.Header and _g.Header.AssetManifest != null:
		for entry in _g.Header.AssetManifest:
			current_ids[entry.ID] = entry.Name

	# New DD session? Compare OS PID with stored session PID
	var current_pid = str(OS.get_process_id())
	var stored_pid = _read_session_pid()
	if stored_pid != current_pid:
		# New DD launch — wipe known packs from previous session
		_write_session_pid(current_pid)
		var dir = Directory.new()
		if dir.file_exists(KNOWN_PACKS_FILE):
			dir.remove(KNOWN_PACKS_FILE)
			print("[PackCacheFix] Nouvelle session DD — known packs effacé.")

	# All packs seen this session
	var known = _read_known_packs()

	# Add current manifest to known
	for pack_id in current_ids:
		known[pack_id] = current_ids[pack_id]
	_write_known_packs(known)

	# Get AssetPacks dict
	var ap = null
	if _g.Editor.owner != null and "AssetPacks" in _g.Editor.owner:
		ap = _g.Editor.owner.AssetPacks
	if ap == null:
		return false

	# Stale = in known, NOT in current manifest, AND still in AssetPacks
	var stale_ids = []
	var stale_names = []
	for pack_id in known:
		if not (pack_id in current_ids) and (pack_id in ap):
			stale_ids.append(pack_id)
			stale_names.append(known[pack_id])

	if stale_ids.size() == 0:
		print("[PackCacheFix] Aucun pack stale.")
		return true

	print("[PackCacheFix] %d pack(s) stale détectés" % stale_ids.size())
	if _is_popup_enabled():
		_show_popup(stale_ids, stale_names)
	else:
		print("[PackCacheFix] Popup disabled — purging silently.")
		_run_purge(stale_ids, stale_names)
	return true


func _is_popup_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("pack_cache_popup")

# ------------------------------------------------------------------
# Popup (pack_embed_fix style)
# ------------------------------------------------------------------
func _show_popup(stale_ids : Array, stale_names : Array) -> void:
	var count = stale_names.size()
	var MAX_DISPLAY = 10
	var msg = "%d asset pack(s) from a previous map are still cached:\n\n" % count
	if count <= MAX_DISPLAY:
		for n in stale_names:
			msg += "  • %s\n" % n
	else:
		for i in range(MAX_DISPLAY):
			msg += "  • %s\n" % stale_names[i]
		msg += "  …and %d other(s)\n" % (count - MAX_DISPLAY)
	msg += "\nPurge them to prevent placing assets that will be lost on reload."

	var dialog = AcceptDialog.new()
	dialog.window_title = "Pack Cache Fix"
	dialog.dialog_text = msg
	dialog.get_ok().text = "Purge Now"
	dialog.set_meta("stale_ids", stale_ids)
	dialog.set_meta("stale_names", stale_names)
	dialog.connect("confirmed", self, "_on_confirmed", [dialog])
	dialog.connect("popup_hide", self, "_on_dialog_closed", [dialog])

	_add_dialog(dialog)
	dialog.popup_exclusive = true
	dialog.popup_centered(Vector2(480, 200))
	_deferred_style(dialog)

func _add_dialog(dialog : Node) -> void:
	var windows = _g.Editor.get_node("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dialog)
	elif _g.World and is_instance_valid(_g.World) and _g.World.is_inside_tree():
		_g.World.get_tree().root.add_child(dialog)
	else:
		_g.Editor.add_child(dialog)

func _deferred_style(dialog : Node) -> void:
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.one_shot = true
	timer.connect("timeout", self, "_style_dialog_buttons", [dialog, timer])
	_g.World.get_tree().root.add_child(timer)
	timer.start()

func _style_dialog_buttons(dialog : Node, timer : Timer) -> void:
	timer.queue_free()
	if not is_instance_valid(dialog):
		return
	for child in dialog.get_children():
		if child is Label:
			child.align = Label.ALIGN_CENTER
	for child in dialog.get_children():
		if child is HBoxContainer:
			for btn in child.get_children():
				if btn is Button:
					var existing = btn.get_stylebox("normal")
					if existing != null and existing is StyleBoxFlat:
						var s = existing.duplicate()
						s.border_color = Color(0.6, 0.6, 0.6, 0.7)
						s.set_border_width_all(1)
						s.content_margin_left = 20
						s.content_margin_right = 20
						s.content_margin_top = 6
						s.content_margin_bottom = 6
						btn.add_stylebox_override("normal", s)
						var h = existing.duplicate()
						h.border_color = Color(0.8, 0.8, 0.8, 0.9)
						h.set_border_width_all(1)
						h.content_margin_left = 20
						h.content_margin_right = 20
						h.content_margin_top = 6
						h.content_margin_bottom = 6
						btn.add_stylebox_override("hover", h)

func _on_dialog_closed(dialog : Node) -> void:
	if is_instance_valid(dialog):
		dialog.queue_free()

# ------------------------------------------------------------------
# Purge confirmed
# ------------------------------------------------------------------
func _on_confirmed(dialog) -> void:
	var stale_ids = dialog.get_meta("stale_ids") if dialog.has_meta("stale_ids") else []
	var stale_names = dialog.get_meta("stale_names") if dialog.has_meta("stale_names") else []
	_run_purge(stale_ids, stale_names)


func _run_purge(stale_ids : Array, stale_names : Array) -> void:
	print("[PackCacheFix] === PURGE START ===")

	if stale_ids.size() == 0:
		return

	# Build stale prefixes and names
	_stale_pack_names = {}
	_stale_ids_dict = {}
	for sid in stale_ids:
		_stale_ids_dict[sid] = true
	for sn in stale_names:
		_stale_pack_names[sn] = true
	print("[PackCacheFix] Stale pack names: %s" % str(_stale_pack_names.keys()))

	# Erase from AssetPacks
	if _g.Editor.owner != null and "AssetPacks" in _g.Editor.owner:
		var ap = _g.Editor.owner.AssetPacks
		var before = ap.size()
		for sid in stale_ids:
			if sid in ap:
				ap.erase(sid)
		print("[PackCacheFix] AssetPacks: %d → %d" % [before, ap.size()])

	# Notify terrain_slots_extended so extra slots assigned to purged packs
	# are cleared as well (all levels + caches + picker catalog)
	if Engine.has_meta("terrain_slots_extended_singleton"):
		var tse = Engine.get_meta("terrain_slots_extended_singleton")
		if tse != null and tse.has_method("purge_stale_packs"):
			tse.purge_stale_packs(stale_ids)

	# Get menu references
	var olp = _g.Editor.get_node("VPartition/Panels/HSplit/ObjectLibraryPanel")
	if olp == null and "ObjectLibraryPanel" in _g.Editor:
		olp = _g.Editor.ObjectLibraryPanel
	_obj_menu = olp.get_node("Margins/VAlign/ObjectsMenu") if olp != null else null

	var plp = _g.Editor.get_node("VPartition/Panels/HSplit/PathLibraryPanel")
	if plp == null and "PathLibraryPanel" in _g.Editor:
		plp = _g.Editor.PathLibraryPanel
	_path_menu = plp.get_node("Margins/VAlign/PathsMenu") if plp != null else null

	# Initial purge
	if _obj_menu != null:
		var r = _purge_itemlist(_obj_menu)
		print("[PackCacheFix] ObjectsMenu: removed %d stale, %d remaining" % [r, _obj_menu.get_item_count()])
	if _path_menu != null:
		var r = _purge_itemlist(_path_menu)
		print("[PackCacheFix] PathsMenu: removed %d stale, %d remaining" % [r, _path_menu.get_item_count()])

	# Activate continuous monitoring
	_purge_active = true
	_purge_timer = 0.0

	# Scan all tool panels and windows
	_discover_tool_menus()
	_purge_terrain_tabs()
	_hook_signals(olp, plp)

	print("[PackCacheFix] === PURGE ACTIVE (monitoring %d menus) ===" % _all_menus.size())

# ------------------------------------------------------------------
# Continuous re-purge
# ------------------------------------------------------------------
func _check_and_repurge() -> void:
	if _in_purge:
		return
	_in_purge = true
	for entry in _all_menus:
		var m = entry.menu
		if m == null or not is_instance_valid(m):
			continue
		var count = m.get_item_count()
		var changed = count != entry.last_count
		if not changed and not entry.dirty:
			continue
		# Invisible menus can't be interacted with: defer their purge
		if not m.is_visible_in_tree():
			entry.dirty = true
			entry.last_count = count
			continue
		var removed = _purge_itemlist(m)
		entry.dirty = false
		if removed > 0:
			print("[PackCacheFix] Re-purged %s: %d → %d (-%d)" % [entry.label, count, m.get_item_count(), removed])
		entry.last_count = m.get_item_count()
	_in_purge = false

# ------------------------------------------------------------------
# Discover all ItemLists
# ------------------------------------------------------------------
func _discover_tool_menus() -> void:
	_all_menus = []

	if _obj_menu != null:
		_all_menus.append({menu = _obj_menu, label = "ObjectsMenu", last_count = _obj_menu.get_item_count(), dirty = false})
	if _path_menu != null:
		_all_menus.append({menu = _path_menu, label = "PathsMenu", last_count = _path_menu.get_item_count(), dirty = false})

	if "Toolset" in _g.Editor and _g.Editor.Toolset != null:
		if "ToolPanels" in _g.Editor.Toolset:
			var tp = _g.Editor.Toolset.ToolPanels
			if tp is Dictionary:
				for key in tp.keys():
					var panel = tp[key]
					if panel != null:
						_find_itemlists(panel, "TP/%s" % key)

	if "Windows" in _g.Editor:
		var wins = _g.Editor.Windows
		if wins is Dictionary:
			for key in wins.keys():
				var win = wins[key]
				if win != null:
					_find_itemlists(win, "Win/%s" % key)

	# Libraries relocated by library_right_panel are reparented out of
	# ToolPanels: walk the right panel too (also covers dynamic attachments)
	var lrp_panel = _find_lrp_panel()
	if lrp_panel != null:
		_find_itemlists(lrp_panel, "LRP")

	# Initial purge of all discovered menus (single pass)
	for entry in _all_menus:
		var m = entry.menu
		if m == _obj_menu or m == _path_menu:
			continue  # already purged in _run_purge
		var r = _purge_itemlist(m)
		entry.last_count = m.get_item_count()
		if r > 0:
			print("[PackCacheFix] Purged %s: -%d items (%d remaining)" % [entry.label, r, m.get_item_count()])

func _find_itemlists(node, path_prefix : String) -> void:
	if node is ItemList:
		if node == _obj_menu or node == _path_menu:
			return
		for entry in _all_menus:
			if entry.menu == node:
				return
		_all_menus.append({menu = node, label = "%s/%s" % [path_prefix, node.name], last_count = node.get_item_count(), dirty = false})
		return
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		_find_itemlists(child, "%s/%s" % [path_prefix, node.name])

# Returns 1 = stale pack, 0 = live pack (definitively not stale), -1 = unknown
func _path_verdict(path : String) -> int:
	if not path.begins_with("res://packs/"):
		return -1
	var rest = path.substr(12)
	var slash = rest.find("/")
	if slash <= 0:
		return -1
	if rest.substr(0, slash) in _stale_ids_dict:
		return 1
	return 0

func _find_lrp_panel():
	# Preferred: the instance published by library_right_panel
	if _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		var lrp = _g.ModMapData.get("_library_right_panel")
		if lrp != null and "_panel" in lrp:
			var p = lrp._panel
			if p != null and is_instance_valid(p):
				return p
	# Fallback: locate the panel node by name
	if _g.Editor != null:
		return _g.Editor.find_node("UP_LibraryRightPanel", true, false)
	return null

func _is_item_stale(menu, i : int) -> bool:
	# Cheapest sufficient check first: pack id extracted from icon path,
	# O(1) dict lookup. A live-pack verdict short-circuits the rest.
	var icon = menu.get_item_icon(i)
	if icon != null and icon is Object and "resource_path" in icon:
		var v = _path_verdict(icon.resource_path)
		if v == 1:
			return true
		if v == 0:
			return false
	var meta = menu.get_item_metadata(i)
	if meta != null:
		var meta_path = ""
		if meta is Object and "resource_path" in meta:
			meta_path = meta.resource_path
		elif meta is String:
			meta_path = meta
		if meta_path != "":
			var v2 = _path_verdict(meta_path)
			if v2 == 1:
				return true
			if v2 == 0:
				return false
	if _stale_pack_names.size() > 0:
		var text = menu.get_item_text(i)
		if text != "" and _is_stale_pack_name(text):
			return true
	return false

# ------------------------------------------------------------------
# Terrain pack tabs
# ------------------------------------------------------------------
func _purge_terrain_tabs() -> void:
	if not ("Windows" in _g.Editor) or not ("TerrainWindow" in _g.Editor.Windows):
		return
	var tw = _g.Editor.Windows["TerrainWindow"]
	if tw == null:
		return

	var pack_list = tw.get_node_or_null("Margins/Splitter/PackList")
	if pack_list == null or not (pack_list is ItemList):
		return

	var to_remove = []
	for i in range(pack_list.get_item_count()):
		if _is_stale_pack_name(pack_list.get_item_text(i)):
			to_remove.append(i)

	to_remove.invert()
	for idx in to_remove:
		pack_list.remove_item(idx)

	if to_remove.size() > 0:
		_force_itemlist_refresh(pack_list)
		print("[PackCacheFix] TerrainWindow PackList: removed %d stale packs" % to_remove.size())

	_terrain_pack_list = pack_list
	_all_menus.append({menu = pack_list, label = "TerrainPackList", last_count = pack_list.get_item_count(), dirty = false})

func _is_stale_pack_name(text : String) -> bool:
	if text in _stale_pack_names:
		return true
	for sn in _stale_pack_names:
		if text.begins_with(sn):
			return true
	return false

# ------------------------------------------------------------------
# Signal hooks
# ------------------------------------------------------------------
func _hook_signals(olp, plp) -> void:
	if olp != null:
		var search = olp.get_node("Margins/VAlign/Filters/Search/SearchLineEdit")
		if search != null:
			search.connect("text_changed", self, "_on_search_changed")
			print("[PackCacheFix] Hooked ObjectLibrary search")
		for btn_name in ["AllButton", "UsedButton"]:
			var btn = olp.get_node("Margins/VAlign/Align/%s" % btn_name)
			if btn != null:
				btn.connect("pressed", self, "_on_filter_changed")

	if plp != null:
		var search = plp.get_node("Margins/VAlign/Filters/Search/SearchLineEdit")
		if search != null:
			search.connect("text_changed", self, "_on_search_changed")
			print("[PackCacheFix] Hooked PathLibrary search")

	if "Toolset" in _g.Editor and _g.Editor.Toolset != null:
		if "ToolPanels" in _g.Editor.Toolset:
			var tp = _g.Editor.Toolset.ToolPanels
			if tp is Dictionary:
				for key in tp.keys():
					var panel = tp[key]
					if panel != null and panel.has_signal("visibility_changed"):
						panel.connect("visibility_changed", self, "_on_tool_switched")
				print("[PackCacheFix] Hooked tool panel visibility")

	for entry in _all_menus:
		var m = entry.menu
		if m != null and m.has_signal("item_rect_changed"):
			if not m.is_connected("item_rect_changed", self, "_on_menu_changed"):
				m.connect("item_rect_changed", self, "_on_menu_changed")
	print("[PackCacheFix] Hooked item_rect_changed on %d menus" % _all_menus.size())

func _on_search_changed(_text) -> void:
	_schedule_purge()

func _on_filter_changed() -> void:
	_schedule_purge()

func _on_tool_switched() -> void:
	_schedule_purge()

func _on_menu_changed() -> void:
	if not _purge_active or _in_purge:
		return
	_schedule_purge()

# Collapses any number of triggers in the same frame into one purge
func _schedule_purge() -> void:
	if _purge_queued:
		return
	_purge_queued = true
	call_deferred("_deferred_purge_delayed")

func _deferred_purge_delayed() -> void:
	call_deferred("_deferred_purge")

func _deferred_purge() -> void:
	_purge_queued = false
	if not _purge_active or _in_purge:
		return
	_in_purge = true
	for entry in _all_menus:
		var m = entry.menu
		if m == null or not is_instance_valid(m):
			continue
		# Invisible menus can't be interacted with: defer their purge
		if not m.is_visible_in_tree():
			entry.dirty = true
			continue
		var r = _purge_itemlist(m)
		entry.dirty = false
		entry.last_count = m.get_item_count()
	_in_purge = false

# ------------------------------------------------------------------
# ItemList purge
# ------------------------------------------------------------------
func _purge_itemlist(menu) -> int:
	var to_remove = []

	for i in range(menu.get_item_count()):
		if _is_item_stale(menu, i):
			to_remove.append(i)

	var removed = to_remove.size()

	if removed >= REBUILD_THRESHOLD:
		# Mass removal: snapshot survivors, clear, re-add (single O(M) pass)
		_rebuild_without(menu, to_remove)
	else:
		to_remove.invert()
		for idx in to_remove:
			menu.remove_item(idx)

	if removed > 0:
		_force_itemlist_refresh(menu)

	return removed

# Rebuilds the ItemList without the items at indices in to_remove,
# preserving per-item properties, selection and scroll position.
func _rebuild_without(menu, to_remove : Array) -> void:
	var stale_set = {}
	for idx in to_remove:
		stale_set[idx] = true

	var scroll = null
	for i in range(menu.get_child_count()):
		if menu.get_child(i) is VScrollBar:
			scroll = menu.get_child(i)
			break
	var scroll_val = scroll.value if scroll != null else 0.0

	var items = []
	for i in range(menu.get_item_count()):
		if i in stale_set:
			continue
		items.append({
			text = menu.get_item_text(i),
			icon = menu.get_item_icon(i),
			meta = menu.get_item_metadata(i),
			tooltip = menu.get_item_tooltip(i),
			tooltip_enabled = menu.is_item_tooltip_enabled(i),
			disabled = menu.is_item_disabled(i),
			selectable = menu.is_item_selectable(i),
			icon_modulate = menu.get_item_icon_modulate(i),
			icon_region = menu.get_item_icon_region(i),
			bg = menu.get_item_custom_bg_color(i),
			fg = menu.get_item_custom_fg_color(i),
			selected = menu.is_selected(i),
		})

	menu.clear()
	for it in items:
		var idx = menu.get_item_count()
		menu.add_item(it.text, it.icon, it.selectable)
		menu.set_item_metadata(idx, it.meta)
		menu.set_item_tooltip(idx, it.tooltip)
		menu.set_item_tooltip_enabled(idx, it.tooltip_enabled)
		menu.set_item_disabled(idx, it.disabled)
		menu.set_item_icon_modulate(idx, it.icon_modulate)
		menu.set_item_icon_region(idx, it.icon_region)
		menu.set_item_custom_bg_color(idx, it.bg)
		menu.set_item_custom_fg_color(idx, it.fg)
		if it.selected:
			menu.select(idx, false)

	if scroll != null:
		scroll.value = scroll_val

func _force_itemlist_refresh(menu) -> void:
	for i in range(menu.get_child_count()):
		var child = menu.get_child(i)
		if child is VScrollBar:
			var val = child.value
			child.value = val + 0.001
			child.value = val
			return
	var cc = menu.is_clipping_contents()
	menu.set_clip_contents(!cc)
	menu.set_clip_contents(cc)

# ------------------------------------------------------------------
# Session PID tracking
# ------------------------------------------------------------------
func _read_session_pid() -> String:
	var f = File.new()
	if not f.file_exists(SESSION_FILE):
		return ""
	if f.open(SESSION_FILE, File.READ) != OK:
		return ""
	var pid = f.get_line().strip_edges()
	f.close()
	return pid

func _write_session_pid(pid : String) -> void:
	var f = File.new()
	if f.open(SESSION_FILE, File.WRITE) == OK:
		f.store_line(pid)
		f.close()

# ------------------------------------------------------------------
# Accumulative known packs persistence
# ------------------------------------------------------------------
func _write_known_packs(ids : Dictionary) -> void:
	var f = File.new()
	if f.open(KNOWN_PACKS_FILE, File.WRITE) == OK:
		for pack_id in ids:
			f.store_line(pack_id + "|" + str(ids[pack_id]))
		f.close()

func _read_known_packs() -> Dictionary:
	var f = File.new()
	if not f.file_exists(KNOWN_PACKS_FILE):
		return {}
	if f.open(KNOWN_PACKS_FILE, File.READ) != OK:
		return {}
	var ids = {}
	while not f.eof_reached():
		var line = f.get_line().strip_edges()
		if line == "":
			continue
		var sep = line.find("|")
		if sep > 0:
			ids[line.substr(0, sep)] = line.substr(sep + 1)
		else:
			ids[line] = line
	f.close()
	return ids
