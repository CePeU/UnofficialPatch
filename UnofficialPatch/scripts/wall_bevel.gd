# wall_bevel.gd
# Adds a "Bevel Corners" toggle to the SelectTool panel, shown only when at
# least one wall is selected. It mirrors the WallTool's Bevel option, but for
# already-placed walls: toggling it flips the selected wall(s)' corner joint
# between Bevel and Sharp (Line2D.LineJointMode) and rebuilds their lines.
#
# Le joint est deja serialise nativement par Wall.Save() ("joint"), donc aucune
# persistance n'est necessaire cote mod : un simple RemakeLines() suffit, et le
# changement survit a la sauvegarde/rechargement de la map.
#
# On NE connecte PAS le signal "toggled" : ecrire une propriete C# (Joint) et
# appeler une methode C# (RemakeLines) depuis un callback de signal UI peut
# planter (meme raison que pattern_fix). On sonde donc l'etat du bouton a chaque
# tick (Timer), hors contexte de callback UI, ce qui est sur.

var _g

var _select_tool  = null
var _select_panel = null
var _bevel_button = null

var _timer = null

# Anti-rebond entre "changement de selection" (on synchronise le bouton) et
# "clic utilisateur" (on applique). _bevel_last_pressed memorise l'etat connu du
# bouton ; _bevel_last_walls la signature de la selection de murs.
var _bevel_last_pressed := false
var _bevel_last_walls := []

const CHECK_INTERVAL := 0.15

# Godot 3 Line2D.LineJointMode : 0 = Sharp, 1 = Bevel, 2 = Round. Le WallTool ne
# manipule que Sharp/Bevel ; on fait pareil.
const JOINT_SHARP := 0
const JOINT_BEVEL := 1

# SelectableType.Wall (cf. SelectableType.cs).
const TYPE_WALL := 1


func initialize() -> void:
	_select_tool = _g.Editor.Tools["SelectTool"]
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if _select_panel != null:
		_bevel_button = _create_bevel_button()
	else:
		print("[WallBevel] WARNING: SelectTool panel not found")

	# Cross-session guard: _g.Editor persists across map reloads, so an autostart
	# Timer added by a previous mod instance keeps ticking forever. Free the
	# previous one before adding ours -- otherwise they accumulate per reload.
	if Engine.has_meta("wb_timer"):
		var _old_t = Engine.get_meta("wb_timer")
		if is_instance_valid(_old_t):
			_old_t.queue_free()
	_timer = Timer.new()
	_timer.wait_time = CHECK_INTERVAL
	_timer.autostart = true
	_timer.connect("timeout", self, "_tick")
	Engine.set_meta("wb_timer", _timer)
	_g.Editor.add_child(_timer)
	print("[WallBevel] initialized (button=%s)" % str(_bevel_button != null))


func cleanup() -> void:
	if _timer != null and is_instance_valid(_timer):
		_timer.queue_free()
	_timer = null
	if _bevel_button != null and is_instance_valid(_bevel_button):
		_bevel_button.queue_free()
	_bevel_button = null


func _create_bevel_button():
	# Meme methode d'injection que wall_allow_light : on ajoute un CheckButton
	# dans le conteneur "Align" du panneau (CreateButton avec icone vide leve une
	# erreur ImageLoader), place juste avant les sections d'options cachees.
	var parent = _select_panel.get("Align")
	if parent == null:
		parent = _select_panel.find_node("Align", true, false)
	if parent == null:
		return null
	var btn = CheckButton.new()
	btn.text = "Bevel Corners"
	btn.hint_tooltip = "Bevel or sharpen the corners of the selected wall(s)."
	btn.pressed = false
	btn.visible = false
	# Pas de signal : on sonde l'etat dans _tick (cf. entete).
	parent.add_child(btn)
	var final_idx = parent.get_child_count()
	for i in range(parent.get_child_count()):
		var child = parent.get_child(i)
		if child is VBoxContainer and not child.visible:
			final_idx = i
			break
	parent.move_child(btn, final_idx)
	return btn


func _tick() -> void:
	if _bevel_button == null or not is_instance_valid(_bevel_button):
		return
	if _g == null or _g.Editor == null:
		return
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		_bevel_button.visible = false
		return

	var walls = _get_selected_walls()
	if walls.empty():
		_bevel_button.visible = false
		_bevel_last_walls = []
		return
	_bevel_button.visible = true

	# Signature de la selection : si elle change, on synchronise le bouton sur
	# l'etat du 1er mur (sans appliquer), puis on sort.
	var ids := []
	for w in walls:
		ids.append(w.get_instance_id())
	if ids != _bevel_last_walls:
		_bevel_last_walls = ids
		var beveled = _is_beveled(walls[0])
		_bevel_button.pressed = beveled
		_bevel_last_pressed = beveled
		return

	# Selection stable : un changement d'etat du bouton = clic utilisateur.
	var state = _bevel_button.pressed
	if state != _bevel_last_pressed:
		_apply_to_walls(walls, state)
		_bevel_last_pressed = state


# Recupere les murs de la selection. On reconstruit depuis RawSelectables plutot
# que via Selectables (ToDictionary() peut lever si deux entrees pointent le meme
# Thing apres certains undo/redo). Meme garde que wall_allow_light / light_fix.
func _get_selected_walls() -> Array:
	var out := []
	if _select_tool == null:
		return out
	var raw = _select_tool.get("RawSelectables")
	if raw == null:
		return out
	var seen := {}
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if seen.has(thing):
			continue
		seen[thing] = true
		var type = -1
		if _select_tool.has_method("GetSelectableType"):
			type = _select_tool.call("GetSelectableType", thing)
		if int(type) == TYPE_WALL:
			out.append(thing)
	return out


func _is_beveled(wall) -> bool:
	if wall == null or not is_instance_valid(wall):
		return false
	var j = wall.get("Joint")
	return typeof(j) == TYPE_INT and int(j) == JOINT_BEVEL


func _apply_to_walls(walls: Array, beveled: bool) -> void:
	var before := _capture_states(walls)
	for wall in walls:
		_set_bevel(wall, beveled)
	var after := _capture_states(walls)
	_record_change(before, after)


func _set_bevel(wall, beveled: bool) -> void:
	if wall == null or not is_instance_valid(wall):
		return
	wall.set("Joint", JOINT_BEVEL if beveled else JOINT_SHARP)
	if wall.has_method("RemakeLines"):
		wall.RemakeLines()


# ── Undo helpers ──────────────────────────────────────────────────────────────
# On memorise l'etat par empreinte geometrique (comme wall_allow_light) : le
# bevel ne modifie pas la geometrie, donc l'empreinte reste valide au moment de
# l'undo/redo pour retrouver le bon mur.

func _capture_states(walls: Array) -> Array:
	var out := []
	for wall in walls:
		if not is_instance_valid(wall):
			continue
		var fp = _wall_fingerprint(wall)
		if fp == "":
			continue
		out.append({
			"fingerprint": fp,
			"beveled": _is_beveled(wall),
		})
	return out


func _record_change(before: Array, after: Array) -> void:
	if before.empty() or after.empty() or before.size() != after.size():
		return
	var changed := false
	for i in range(before.size()):
		if before[i]["beveled"] != after[i]["beveled"]:
			changed = true
			break
	if not changed:
		return
	var undo = _get_undo_lib()
	if undo == null:
		return
	undo.record_callback(
		self, "_restore_states", [before],
		self, "_restore_states", [after])


func _restore_states(states: Array) -> void:
	for entry in states:
		var wall = _find_wall_by_fingerprint(entry["fingerprint"])
		if wall == null:
			continue
		_set_bevel(wall, entry["beveled"])
	# Resynchroniser le bouton pour que le prochain tick ne relise pas ca comme
	# un clic utilisateur.
	if _bevel_button != null and is_instance_valid(_bevel_button):
		var walls = _get_selected_walls()
		if not walls.empty():
			var beveled = _is_beveled(walls[0])
			_bevel_button.pressed = beveled
			_bevel_last_pressed = beveled


func _wall_fingerprint(wall) -> String:
	var pts = wall.get("Points")
	if pts == null or pts.size() == 0:
		return ""
	var parts := []
	for p in pts:
		parts.append(str(int(p.x)) + "," + str(int(p.y)))
	var tex = wall.get("Texture")
	var tex_path = ""
	if tex != null:
		tex_path = tex.resource_path
	return tex_path + "|" + PoolStringArray(parts).join(";")


func _find_wall_by_fingerprint(fp: String):
	if _g == null or _g.World == null:
		return null
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return null
	var walls_node = level.get("Walls")
	if walls_node == null:
		return null
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall) or not wall.has_method("RemakeLines"):
			continue
		if _wall_fingerprint(wall) == fp:
			return wall
	return null


func _get_undo_lib():
	if _g == null or _g.get("ModMapData") == null:
		return null
	return _g.ModMapData.get("_undo_lib")
