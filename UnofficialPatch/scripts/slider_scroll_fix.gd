# slider_scroll_fix.gd
# Makes the mouse wheel over a Slider change its value instead of scrolling the
# surrounding panel, by enabling Godot's native wheel-to-value handling
# (Range.scrollable = true) on every slider. Global: covers current widgets and
# ones added later (dynamic panels) via SceneTree.node_added.
#
# SpinBox consumes the wheel natively when editable, so it is left alone.
#
# Note: the "events fall through / assets get selected / stuck routing" behaviour
# seen when the left panel is widened by the third-party ResizeLeftPanel mod is
# NOT caused here -- it comes from ui_util's panel-edge detection no longer
# recognising an over-wide panel as UI. That is fixed in ui_util.gd, not here.
#
# This script is a Reference (like every submod), NOT a Node: the SceneTree is
# obtained through _g.World, exactly like zoom_unlock does.

var _g
var ui_util

const _HOOK_META := "_ssf_hooked"
const _MAX_DEPTH := 32

var _tree = null
var _destroyed := false


func initialize() -> void:
	_tree = _resolve_tree()
	if _tree == null:
		return
	# Fix sliders that already exist.
	_scan(_tree.root, 0)
	# Fix sliders created later (dynamic panels, tool options, popups...).
	if not _tree.is_connected("node_added", self, "_on_node_added"):
		_tree.connect("node_added", self, "_on_node_added")


func cleanup() -> void:
	_destroyed = true
	if _tree != null and _tree.is_connected("node_added", self, "_on_node_added"):
		_tree.disconnect("node_added", self, "_on_node_added")


func _resolve_tree():
	if _g != null and _g.World and _g.World is Node:
		return _g.World.get_tree()
	return null


# Kept ultra-light: fired for EVERY node added to the tree.
func _on_node_added(node: Node) -> void:
	if _destroyed:
		return
	if node is Slider:
		_hook(node)


func _scan(node: Node, depth: int) -> void:
	if depth > _MAX_DEPTH or not is_instance_valid(node):
		return
	if node is Slider:
		_hook(node)
	for i in node.get_child_count():
		_scan(node.get_child(i), depth + 1)


func _hook(ctl: Control) -> void:
	if ctl.has_meta(_HOOK_META):
		return
	ctl.set_meta(_HOOK_META, true)
	# Native wheel-to-value: consumes the wheel over the slider (so the panel no
	# longer scrolls) without a custom accept_event() of our own.
	ctl.scrollable = true
