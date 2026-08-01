# select_cursor_fix.gd
# Bug vanilla : dans SelectTool, le cursor change sur survol d'un handle
# de la transform box (resize/move/rotate). Si on quitte le tool via
# raccourci clavier (X, Echap, etc.), le cursor reste bloqué partout
# sur le canvas jusqu'au reload de la map.
#
# Cause exacte (trouvée via scan du scene tree) :
#   DD modifie Content.mouse_default_cursor_shape — le Control principal
#   du canvas, à /root/Master/Editor/VPartition/Panels/HSplit/Content —
#   pendant le survol d'un handle (12=FDIAGSIZE, 11=BDIAGSIZE, 13=MOVE,
#   7=CAN_DROP selon la zone) mais ne le reset jamais lorsque le tool
#   change. Le shape stuck persiste sur tout le Content, d'où le cursor
#   bloqué sur tout le canvas. L'UI était également stuck dans les tests
#   initiaux à cause d'une texture custom resize que DD avait collée au
#   slot CURSOR_ARROW.
#
# Fix : au quit de SelectTool, on remet Content.mouse_default_cursor_shape
# à CURSOR_ARROW, et on clear la texture custom du slot CURSOR_ARROW.

var _g
var _last_tool := ""
var _content: Control = null


func initialize() -> void:
	pass


func start() -> void:
	if _g != null and _g.Editor != null:
		_last_tool = _active_tool_name()


func update(_delta) -> void:
	if _g == null or _g.Editor == null:
		return
	var cur = _active_tool_name()
	if cur == _last_tool:
		return
	if _last_tool == "SelectTool" and cur != "SelectTool":
		_reset_canvas_cursor()
	_last_tool = cur


func _reset_canvas_cursor() -> void:
	# Lazy resolve du node Content (le scene tree n'est pas forcément
	# prêt au moment de initialize()).
	if _content == null or not is_instance_valid(_content):
		var node = _g.World.get_tree().root.get_node_or_null(
			"Master/Editor/VPartition/Panels/HSplit/Content")
		if node != null and node is Control:
			_content = node
	if _content != null and is_instance_valid(_content):
		_content.mouse_default_cursor_shape = Control.CURSOR_ARROW
	# Clear aussi le slot ARROW au cas où DD y aurait collé une texture
	# leftover (constaté dans les tests : cursor stuck aussi sur l'UI).
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	# Godot ne reconsulte mouse_default_cursor_shape qu'au prochain
	# mouse motion event. Sans bouger la souris, le cursor garderait son
	# ancienne forme. On force un mouse motion en warping la souris vers
	# sa propre position — visuellement no-op, mais ça déclenche le
	# refresh du cursor immédiatement.
	var vp = _g.World.get_viewport()
	if vp != null:
		Input.warp_mouse_position(vp.get_mouse_position())


# ── Per-frame cached editor state (published by Main.gd, Engine metadata) ──
# Reading native/C# editor properties marshals a fresh GDScript object across
# the interop boundary on EVERY access; with dozens of submods polling every
# frame this is a steady allocation stream (background commit-charge growth).
# Main.gd reads ActiveToolName once per frame and publishes it; we read the
# shared copy here. THREE rules, each learned from a measured failure:
#   1. PRECONDITION: never serve a cached name when this mod's _g.Editor is
#      unreachable — callers would reach into editor objects that are unsafe
#      to touch (native access violation c0000005 on tool switch / map churn).
#   2. MEMOIZATION: the _g.Editor null-check itself marshals a wrapper per
#      access; doing it per call cost as much as the problem this cache
#      solves (+0.037 MB/s, +12% main CPU over 600 s). One read per mod per
#      process tick keeps the safety signal at ~1/10th the volume.
#   3. FORCED COPY: never hand out a COW reference to the String stored in
#      the shared Dictionary — hence "%s" % v.
var _uu_ed_frame := -1
var _uu_ed_ok := false


func _active_tool_name() -> String:
	if not _uu_editor_reachable():
		return ""
	if Engine.has_meta("_uu_editor_state"):
		var s = Engine.get_meta("_uu_editor_state")
		if s is Dictionary:
			var v = s.get("active_tool_name")
			if v is String:
				return "%s" % v
	return str(_g.Editor.ActiveToolName)


func _uu_editor_reachable() -> bool:
	var f = Engine.get_idle_frames()
	if f == _uu_ed_frame:
		return _uu_ed_ok
	_uu_ed_frame = f
	_uu_ed_ok = _g != null and _g.Editor != null
	return _uu_ed_ok
