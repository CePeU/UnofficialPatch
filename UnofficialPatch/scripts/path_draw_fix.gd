# path_draw_fix.gd
# Keeps path/wall/pattern/roof preview following the mouse
# even when the cursor leaves the viewport during drawing.

var script_class = "tool"
var _g
var ui_util  # injecte par Main.gd (peut etre null si desactive en debug)
var input_listener: Node

var _watched_tools = ["PathTool", "WallTool", "PatternShapeTool", "RoofTool", "FloorShapeTool"]

# Pour chaque tool, le nom de la methode "Update<Thing>" qui force un
# refresh du draw en cours en fonction de MousePosition (mis a jour par
# nous). Une seule de ces methodes existe par tool. On tente chacune
# (has_method) pour ne pas dependre d'un nommage particulier.
var _update_methods = ["UpdatePath", "UpdateWall", "UpdateShape", "UpdatePattern", "UpdateRoof", "UpdateFloor"]

const _META_KEY = "PathDrawFixListener"


func initialize():
	_cleanup_old_listener()
	_install_input_listener()
	print("[PathDrawFix] initialized")


func _cleanup_old_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
		Engine.set_meta(_META_KEY, null)
	if is_instance_valid(input_listener):
		input_listener.handler = null
		input_listener.queue_free()
	input_listener = null


func _install_input_listener():
	input_listener = Node.new()
	input_listener.name = "PathDrawFixListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(event):\n\tif handler == null:\n\t\treturn\n\thandler._on_input(event)\n"
	s.reload()
	input_listener.set_script(s)
	input_listener.handler = self
	Engine.set_meta(_META_KEY, input_listener)
	_g.Editor.get_tree().get_root().call_deferred("add_child", input_listener)


# Retourne le tool actif s'il est dans _watched_tools, sinon null.
# On ne tente plus de detecter "draw en cours" via ActivePath : c'etait
# specifique a PathTool, et bloquait le fix pour les autres outils. Il
# suffit de pousser MousePosition + appeler la methode Update* du tool ;
# le tool sait lui-meme s'il est en plein draw.
func _get_active_drawing_tool():
	if _g == null:
		return null
	var editor = _g.get("Editor")
	if editor == null or not is_instance_valid(editor):
		return null
	var atn = editor.get("ActiveToolName")
	if atn == null or not (atn in _watched_tools):
		return null
	var tools = editor.get("Tools")
	if tools == null:
		return null
	var tool = tools.get(atn)
	if tool == null or not is_instance_valid(tool):
		return null
	return tool


# Position monde de la souris via get_global_mouse_position() : exactement
# le meme espace de coordonnees que celui utilise par DD en interne
# (viewport + canvas transform), donc aucune conversion manuelle susceptible
# de diverger selon la resolution ou le scaling HiDPI de l'OS. L'ancienne
# conversion basee sur event.position pouvait produire un decalage constant
# sur certaines configurations (ex: 2560x1600 avec scaling Windows).
func _mouse_world_position(world_ui) -> Vector2:
	if world_ui is CanvasItem:
		return world_ui.get_global_mouse_position()
	var vp = world_ui.get_viewport()
	return vp.get_canvas_transform().affine_inverse().xform(vp.get_mouse_position())


func _on_input(event):
	if not (event is InputEventMouseMotion):
		return
	_update_preview()


func _update_preview():
	if _g == null:
		return
	var world_ui = _g.get("WorldUI")
	if world_ui == null or not is_instance_valid(world_ui):
		return
	var tool = _get_active_drawing_tool()
	if tool == null:
		return
	# Ne rien faire quand la souris est dans la zone carte : DD y met a jour
	# MousePosition nativement et notre ecriture ne ferait que rivaliser
	# avec la sienne (ordre de propagation _input non garanti). Ecraser
	# MousePosition avec une valeur decalee etait masque par le snap (la
	# position etait quantifiee sur la grille), mais devenait visible des
	# que le snap etait desactive en cours de trace. Le fix n'est utile que
	# lorsque le curseur est au-dessus de l'UI / hors zone carte, la ou DD
	# ne traite plus le motion.
	if ui_util != null and not ui_util.is_mouse_over_ui(input_listener):
		return
	var world_pos = _mouse_world_position(world_ui)
	world_ui.set("MousePosition", world_pos)
	world_ui.set("IsMouseMoving", true)
	# Tente la bonne methode Update* du tool. On essaie chaque candidat ;
	# une seule existera par tool. Sans ca, certains tools (Wall, Pattern,
	# etc.) ne recalculaient pas leur preview avec la nouvelle position.
	for m in _update_methods:
		if tool.has_method(m):
			tool.call(m)
			return


func update(_delta):
	pass


# Appele par Main.gd lors d'un hot-toggle off (Draw Over UI = false).
# Detache l'input listener globalement pour ne plus tracker la souris
# hors viewport.
func cleanup():
	_cleanup_old_listener()
