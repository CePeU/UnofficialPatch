# clipboard_context.gd
# Right-click context menu provider for clipboard actions:
# Copy, Cut, Paste, Paste in Place, Delete.
#
# Registered with right_click_util. Delegates every action to clipboard_fix,
# which owns the copy/paste/delete machinery (copy centre, wall clipboard,
# snap, undo records, CMT bridge...). This provider only decides which items
# to show and forwards the user's choice.
#
# Visibility rules:
#   - Copy / Cut / Delete   : only when there is a copyable selection.
#   - Paste / Paste in Place : only when the clipboard holds something.
# On a selection (near path) all applicable items show; in empty space
# (void path) only Paste / Paste in Place show.

var _g

# Reference to clipboard_fix.gd (injected by Main.gd at boot).
var clipboard_fix = null

# World position captured at right-click time, BEFORE the popup steals the
# hover (WorldUI.MousePosition would otherwise report the popup location by
# the time the user clicks "Paste"). Used as the paste-at-cursor target.
var _paste_world_pos := Vector2.ZERO

# Text selection captured at right-click time. text_transform clears its
# _selected_texts on any left-click it treats as "empty space" (text_transform
# line ~613). The click that dismisses the popup and triggers our action is
# processed by text_transform's _input() BEFORE the popup's id_pressed fires
# (Godot dispatches _input before GUI), and is_mouse_over_ui() doesn't reliably
# see our dynamically-created popup (3-frame cache + signal-maintained popup
# registry). So by the time context_copy/cut/delete run, the text selection is
# already gone. We snapshot it here (selection intact) and restore it before
# the action. DD asset selection survives the click, so it needs no snapshot.
var _captured_texts := []


func initialize() -> void:
	print("[ClipboardContext] Initialized")


func _capture_paste_pos() -> void:
	if _g != null and _g.WorldUI != null and is_instance_valid(_g.WorldUI):
		_paste_world_pos = _g.WorldUI.MousePosition


# text_transform.gd instance (holds _selected_texts / _clipboard / copy-paste).
func _text_mod():
	if _g == null or not (_g.ModMapData is Dictionary):
		return null
	return _g.ModMapData.get("_ttf_transform")


# Snapshot the current text selection while it is still intact (right-click).
func _capture_text_selection() -> void:
	_captured_texts = []
	var tt = _text_mod()
	if tt == null:
		return
	for t in tt._selected_texts:
		if is_instance_valid(t):
			_captured_texts.append(t)


# Restore the snapshot onto text_transform just before a copy/cut/delete, in
# case the popup-dismissing click cleared it. No-op when nothing was captured
# (so a genuinely empty text selection is left untouched).
func _restore_text_selection() -> void:
	if _captured_texts.size() == 0:
		return
	var tt = _text_mod()
	if tt == null:
		return
	var valid := []
	for t in _captured_texts:
		if is_instance_valid(t):
			valid.append(t)
	if valid.size() > 0:
		tt._selected_texts = valid
		tt._primary_text = valid[0]


func _has_selection() -> bool:
	return clipboard_fix != null and clipboard_fix.has_method("has_copyable_selection") \
		and clipboard_fix.has_copyable_selection()


func _has_clipboard() -> bool:
	return clipboard_fix != null and clipboard_fix.has_method("has_clipboard_content") \
		and clipboard_fix.has_clipboard_content()


# ===== Provider interface (right_click_util) =====

# Selection items (Copy/Cut/Delete) show whenever there is a copyable
# selection — DD assets, walls, OR text_transform texts. Text-only selections
# leave DD's RawSelectables empty, so right_click_util routes them through the
# void path (get_void_context_items); building the same list in both paths is
# what makes Copy appear for text-only. Paste items show whenever the
# clipboard holds something.
func _build_items() -> Array:
	_capture_paste_pos()
	_capture_text_selection()
	var items := []
	var sel = _has_selection()
	var clip = _has_clipboard()
	if sel:
		items.append({label = "Copy", icon = null, action_id = "clip_copy"})
		items.append({label = "Cut", icon = null, action_id = "clip_cut"})
	if clip:
		items.append({label = "Paste", icon = null, action_id = "clip_paste"})
		items.append({label = "Paste in Place", icon = null, action_id = "clip_paste_place"})
	if sel:
		items.append({label = "Delete", icon = null, action_id = "clip_delete"})
	return items


# Called on a right-click near/over the current selection.
func get_context_items(_raw) -> Array:
	return _build_items()


# Called on a right-click in empty space (no near selection) — this is also
# where a text-only selection lands, since DD's RawSelectables is empty.
func get_void_context_items() -> Array:
	return _build_items()


func on_context_action(action_id: String, _raw) -> void:
	if clipboard_fix == null or not is_instance_valid(clipboard_fix):
		return
	match action_id:
		"clip_copy":
			_restore_text_selection()
			clipboard_fix.context_copy()
		"clip_cut":
			_restore_text_selection()
			clipboard_fix.context_cut()
		"clip_paste":
			clipboard_fix.context_paste_at(_paste_world_pos)
		"clip_paste_place":
			clipboard_fix.context_paste_in_place()
		"clip_delete":
			_restore_text_selection()
			clipboard_fix.context_delete()
