# pattern_paint_bucket.gd
# Paint Bucket pour le PatternShape Tool.
#
# Utilisation :
#   - Dans le PatternShapeTool, cliquer sur l'icône seau dans la barre des formes
#   - Clic gauche n'importe où dans la map → remplit la région contenant le clic.
#     Les bordures d'une région peuvent être un mix de : murs (fermés ou ouverts),
#     paths (fermés ou ouverts), et bords de la map. Les formes fermées internes
#     à la région deviennent des trous (multi-trous supporté).
#   - Shift+clic → inclut aussi les PatternShapes existants comme barrières
#   - Cliquer sur une autre forme (rect/circle/polygon) désactive le mode fill
#
# Implémentation :
#   1. Rectangle aux bornes de la map.
#   2. Pour chaque mur/path : inflater la polyline en fine bande (offset_polyline_2d).
#      Les endpoints proches d'un bord de map sont snappés sur le bord pour
#      fermer correctement les régions.
#   3. Soustraire toutes ces bandes du rectangle (clip_polygons_2d).
#   4. Région = polygone contenant le clic ; trous = polygones intérieurs
#      avec winding opposé.
#   5. Bridge-cut chaque trou dans la région pour produire un polygone simple
#      (PatternShape ne supporte pas les holes nativement).

var _g
var ui_util
var input_listener: Node
const _META_KEY = "PatternPaintBucketListener"

# Barre de progression + Annuler (opérations longues)
var _progress_script = null
var _filling := false

# UI
var _bucket_button: Button = null
var _bucket_active := false
var _shape_buttons: Array = []
var _shape_hbox = null
var _prev_mode := -1

# Options "Stopped by" (types de barrières qui bloquent le remplissage)
var _opts_hbox = null
var _cb_walls: CheckBox = null
var _cb_paths: CheckBox = null
var _cb_patterns: CheckBox = null

# Curseur
var _bucket_cursor_tex: Texture = null
var _cursor_applied := false

# Géométrie
const BARRIER_THICKNESS = 2.0       # px de chaque côté de la polyline. Doit être suffisant
                                    # pour que deux barrières perpendiculaires se chevauchent
                                    # de façon robuste au croisement (sinon Clipper peut les
                                    # voir comme juste tangentes, et la peinture passe à travers).
const EDGE_SNAP_THRESHOLD = 16.0    # endpoint à <N px d'un bord → snappé sur le bord
const EDGE_OVERSHOOT = 2.0          # quand on snappe, on dépasse de N px pour bien couper
# Au-delà de N sommets, on saute le test d'auto-intersection O(n²) et on offsette
# directement en bande unique (un path aussi dense est une courbe lisse).
const SELF_INTERSECT_CHECK_MAX = 512


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	_load_cursor_texture()
	_progress_script = ResourceLoader.load(_g.Root + "library/progress_dialog.gd", "GDScript", true)
	if _progress_script == null:
		print("[PatternPaintBucket] WARNING: library/progress_dialog.gd introuvable; pas de barre de progression")
	_inject_ui()
	_install_listener()
	print("[PatternPaintBucket] initialized")


func _new_progress(title: String):
	if _progress_script == null:
		return null
	var pg = _progress_script.new()
	pg._g = _g
	pg.start(title)
	return pg


func _load_cursor_texture():
	var path = _g.Root + "icons/bucket_cursor.png"
	var img = Image.new()
	if img.load(path) != OK:
		print("[PatternPaintBucket] bucket_cursor.png not found at ", path)
		return
	_bucket_cursor_tex = ImageTexture.new()
	_bucket_cursor_tex.create_from_image(img, 0)


func _load_icon_texture(filename: String) -> Texture:
	var path = _g.Root + "icons/" + filename
	var img = Image.new()
	if img.load(path) != OK:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


# ── UI Injection ─────────────────────────────────────────────────────────────

func _inject_ui():
	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null:
		print("[PatternPaintBucket] PatternShapeTool not found")
		return

	var tool_panel = _g.Editor.Toolset.GetToolPanel("PatternShapeTool")
	if tool_panel == null:
		print("[PatternPaintBucket] PatternShapeTool panel not found")
		return

	var align = tool_panel.get("Align")
	if align == null:
		print("[PatternPaintBucket] Align not found")
		return

	# Chercher le HBoxContainer contenant les boutons de forme (toggle group)
	_shape_hbox = null
	for child in align.get_children():
		if child is HBoxContainer:
			var has_toggles = false
			for btn in child.get_children():
				if btn is Button and btn.toggle_mode:
					has_toggles = true
					break
			if has_toggles:
				_shape_hbox = child
				break

	if _shape_hbox == null:
		print("[PatternPaintBucket] Shape buttons HBox not found, inserting before EditPoints")
		var ep_btn = pat_tool.get("EditPoints")
		if ep_btn != null:
			_shape_hbox = ep_btn.get_parent()

	if _shape_hbox == null:
		print("[PatternPaintBucket] Cannot find a place to inject button")
		return

	_shape_buttons = []
	for child in _shape_hbox.get_children():
		if child is Button and child.toggle_mode:
			_shape_buttons.append(child)
			if not child.is_connected("pressed", self, "_on_shape_button_pressed"):
				child.connect("pressed", self, "_on_shape_button_pressed")

	_bucket_button = Button.new()
	_bucket_button.toggle_mode = true
	_bucket_button.hint_tooltip = "Paint Bucket: click any region bounded by the enabled barrier types (see the Stopped by options).\nNote: walls, paths and patterns below the target layer are ignored (the pattern covers them), so set the active layer as high as possible before filling to speed up the computation."
	var icon = _load_icon_texture("bucket.png")
	if icon != null:
		_bucket_button.icon = icon
	_bucket_button.connect("toggled", self, "_on_bucket_toggled")

	_shape_hbox.add_child(_bucket_button)

	_build_options_row(align)

	print("[PatternPaintBucket] Bucket button injected in shape buttons row (%d existing buttons)" % _shape_buttons.size())


# Rangée "Stopped by: [x] Walls [x] Paths [ ] Patterns", visible uniquement quand
# l'outil bucket est actif.
func _build_options_row(align):
	_opts_hbox = HBoxContainer.new()
	_opts_hbox.visible = false

	var lbl = Label.new()
	lbl.text = "Stopped by:"
	_opts_hbox.add_child(lbl)

	_cb_walls = CheckBox.new()
	_cb_walls.text = "Walls"
	_cb_walls.pressed = true
	_opts_hbox.add_child(_cb_walls)

	_cb_paths = CheckBox.new()
	_cb_paths.text = "Paths"
	_cb_paths.pressed = true
	_opts_hbox.add_child(_cb_paths)

	_cb_patterns = CheckBox.new()
	_cb_patterns.text = "Patterns"
	_cb_patterns.pressed = false
	_opts_hbox.add_child(_cb_patterns)

	# Insérer la rangée juste SOUS la rangée des boutons de forme/bucket.
	var parent = _shape_hbox.get_parent()
	parent.add_child(_opts_hbox)
	parent.move_child(_opts_hbox, _shape_hbox.get_index() + 1)


# ── Quand l'utilisateur clique un bouton de forme DD (rect/circle/polygon) ───

func _on_shape_button_pressed():
	if _bucket_active:
		_prev_mode = -1
		_bucket_button.pressed = false


# ── Quand le bucket est toggled ──────────────────────────────────────────────

func _on_bucket_toggled(pressed: bool):
	_bucket_active = pressed
	if _opts_hbox != null:
		_opts_hbox.visible = pressed

	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null: return

	if pressed:
		_prev_mode = pat_tool.get("Mode") if pat_tool.get("Mode") != null else 0
		for btn in _shape_buttons:
			if is_instance_valid(btn):
				btn.pressed = false

		var ep = pat_tool.get("EditPoints")
		if ep != null and ep.get("pressed") == true:
			ep.set("pressed", false)

		_apply_cursor()
		_hide_preview()
	else:
		if _prev_mode >= 0 and _prev_mode < _shape_buttons.size():
			if is_instance_valid(_shape_buttons[_prev_mode]):
				_shape_buttons[_prev_mode].pressed = true

		_remove_cursor()
		_show_preview()

	print("[PatternPaintBucket] Bucket mode: ", pressed)


# ── Preview pointer (le pointeur jaune sur la map) ──────────────────────────

var _saved_cursor_mode := -1


func _hide_preview():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var cur = world_ui.get("CursorMode")
	if cur != null and cur != 0:
		_saved_cursor_mode = cur
	world_ui.set("CursorMode", 0)


func _show_preview():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	if _saved_cursor_mode >= 0:
		world_ui.set("CursorMode", _saved_cursor_mode)
		_saved_cursor_mode = -1
	else:
		world_ui.set("CursorMode", 1)


# ── Listener ─────────────────────────────────────────────────────────────────

func _install_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "PatternPaintBucketListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# ── Curseur ──────────────────────────────────────────────────────────────────

func _apply_cursor():
	if _bucket_cursor_tex != null:
		Input.set_custom_mouse_cursor(_bucket_cursor_tex, Input.CURSOR_ARROW, Vector2(0, 0))
		_cursor_applied = true


func _remove_cursor():
	if _cursor_applied:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_applied = false


func _get_mouse_world_pos() -> Vector2:
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return Vector2.ZERO
	var vp = world_ui.get_viewport()
	if vp == null: return Vector2.ZERO
	var canvas_xform = vp.get_canvas_transform()
	return canvas_xform.affine_inverse().xform(vp.get_mouse_position())


func _is_over_fillable_zone() -> bool:
	# Fillable = dans les bornes de la map (on ne refait pas tout le calcul de
	# région à chaque frame). Si le clic tombe pile sur l'épaisseur d'un mur,
	# _do_fill bailera silencieusement.
	var mouse_world = _get_mouse_world_pos()
	var bounds = _get_map_bounds_polygon()
	if bounds.size() < 3:
		return false
	return _point_in_polygon(mouse_world, bounds)


# ── Détection du PatternShapeTool actif ──────────────────────────────────────

func _is_pattern_tool_active() -> bool:
	if _g == null: return false
	var editor = _g.get("Editor")
	if editor == null: return false
	var tool_name = editor.get("ActiveToolName")
	return tool_name == "PatternShapeTool"


# ── Accès aux données du niveau ──────────────────────────────────────────────

func _get_current_level():
	if _g == null: return null
	var world = _g.get("World")
	if world == null: return null
	return world.call("GetCurrentLevel")


func _get_all_pattern_shapes() -> Array:
	var level = _get_current_level()
	if level == null: return []
	var ps_node = level.get("PatternShapes")
	if ps_node == null: return []
	if not ps_node.has_method("GetShapes"): return []
	var shapes = ps_node.call("GetShapes")
	if shapes == null: return []
	return shapes


# ── Extraction des polylines & polygones ─────────────────────────────────────

func _get_path_polyline(path_node) -> Array:
	# Les paths DD sont des Line2D : `.points` contient la polyline interpolée
	# (avec les points de courbe) en coords locales — c'est ce que voit l'utilisateur.
	# `GlobalEditPoints` ne contient que les sommets d'édition (sans interpolation),
	# trop approximatif pour les courbes.
	var raw = path_node.get("points")
	if raw == null or raw.size() < 2:
		raw = path_node.get("GlobalEditPoints")
		if raw == null: return []
		return _to_array(raw)
	var xform = path_node.get_global_transform()
	var pts = []
	for p in raw:
		pts.append(xform.xform(p))
	return pts


func _get_pattern_polygon(shape) -> Array:
	var raw = shape.get("GlobalPolygon")
	if raw == null: return []
	return _to_array(raw)


func _to_array(pool) -> Array:
	var a = []
	for p in pool: a.append(p)
	return a


# ── Géométrie ────────────────────────────────────────────────────────────────

func _point_in_polygon(point: Vector2, polygon: Array) -> bool:
	var n = polygon.size()
	if n < 3: return false
	var inside = false
	var j = n - 1
	for i in range(n):
		var pi = polygon[i]
		var pj = polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and \
			(point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
	return inside


func _polygon_area(pts: Array) -> float:
	var area = 0.0
	var n = pts.size()
	for i in range(n):
		var j = (i + 1) % n
		area += pts[i].x * pts[j].y
		area -= pts[j].x * pts[i].y
	return abs(area) * 0.5


# Tous les sommets de `inner` doivent être dans `outer`. OK pour des polygones
# qui ne se croisent pas (cas standard après clipping).
func _polygon_inside_polygon(inner: Array, outer: Array) -> bool:
	for p in inner:
		if not _point_in_polygon(p, outer): return false
	return true


# ── Bornes de la map ─────────────────────────────────────────────────────────

func _get_map_bounds_polygon() -> Array:
	if _g == null: return []
	var world = _g.get("World")
	if world == null: return []
	var cs = world.get("GridCellSize")
	var w_tiles = world.get("Width")
	var h_tiles = world.get("Height")
	if cs == null or w_tiles == null or h_tiles == null: return []
	var w = float(w_tiles) * cs.x
	var h = float(h_tiles) * cs.y
	# Pas de marge ici : la map_rect est exactement aux bornes. Les endpoints
	# de murs qui doivent toucher le bord sont snappés avec un léger overshoot.
	return [Vector2(0, 0), Vector2(w, 0), Vector2(w, h), Vector2(0, h)]


func _snap_endpoint_to_map_edge(p: Vector2, threshold: float) -> Vector2:
	if _g == null: return p
	var world = _g.get("World")
	if world == null: return p
	var cs = world.get("GridCellSize")
	var w_tiles = world.get("Width")
	var h_tiles = world.get("Height")
	if cs == null or w_tiles == null or h_tiles == null: return p
	var w = float(w_tiles) * cs.x
	var h = float(h_tiles) * cs.y
	var dl = p.x
	var dr = w - p.x
	var dt = p.y
	var db = h - p.y
	var dmin = min(min(dl, dr), min(dt, db))
	if dmin > threshold:
		return p
	# Snap sur le bord le plus proche, léger overshoot pour garantir que le
	# barrier dépasse vraiment le rectangle après inflate.
	if dmin == dl: return Vector2(-EDGE_OVERSHOOT, p.y)
	if dmin == dr: return Vector2(w + EDGE_OVERSHOOT, p.y)
	if dmin == dt: return Vector2(p.x, -EDGE_OVERSHOOT)
	if dmin == db: return Vector2(p.x, h + EDGE_OVERSHOOT)
	return p


# ── Construction des barriers ────────────────────────────────────────────────

func _build_barriers(stop_walls: bool, stop_paths: bool, stop_patterns: bool) -> Dictionary:
	# Retourne un Dictionary :
	#   closed_pairs : liste de {outer: Array, inner: Array (ou null)} pour les
	#       polylines fermées. Pour chaque mur fermé : on soustrait outer (offset
	#       extérieur, retire mur+pièce) PUIS on ajoute inner (offset intérieur,
	#       réintroduit la pièce comme région à part). Le traitement entrelacé
	#       permet aux outer des murs INTÉRIEURS de couper correctement les inner
	#       des murs EXTÉRIEURS déjà ajoutés.
	#   subs_last : polylines ouvertes + patterns. Soustraits après — ils coupent
	#       à travers tout, y compris les intérieurs de pièces.
	var result = {"closed_pairs": [], "subs_last": []}
	var level = _get_current_level()
	if level == null: return result

	# Layer-cible où le pattern va être posé : on ignore les murs/paths/patterns
	# situés SOUS ce layer (le pattern les recouvre, ils ne doivent pas le borner).
	# null = filtre désactivé (on garde tout, comportement d'avant).
	var min_layer = _get_pattern_target_layer()

	# Murs (ouverts ou fermés)
	var walls_node = level.get("Walls") if stop_walls else null
	if walls_node != null:
		for child in walls_node.get_children():
			if not is_instance_valid(child): continue
			if _is_below_layer(child, min_layer): continue
			var pts_raw = child.get("Points")
			if pts_raw == null or pts_raw.size() < 2: continue
			# Les Points d'un Wall sont en espace LOCAL au nœud : appliquer son
			# transform global (no-op si identité). Sans ça, un mur déplacé/tourné
			# via l'outil Select donne une région décalée.
			var xform = child.get_global_transform()
			var pts = []
			for p in pts_raw:
				pts.append(xform.xform(p))
			var loop = bool(child.get("Loop"))
			_classify_polyline_barrier(pts, loop, result)

	# Paths (ouverts ou fermés)
	var paths_node = level.get("Pathways") if stop_paths else null
	if paths_node != null:
		for child in paths_node.get_children():
			if not is_instance_valid(child): continue
			if _is_below_layer(child, min_layer): continue
			var pts = _get_path_polyline(child)
			if pts.size() < 2: continue
			var loop = bool(child.get("Loop"))
			_classify_polyline_barrier(pts, loop, result)

	# PatternShapes (filled polygons soustraits APRÈS — pour qu'ils coupent à travers les pièces)
	if stop_patterns:
		for shape in _get_all_pattern_shapes():
			if _is_below_layer(shape, min_layer): continue
			var pts = _get_pattern_polygon(shape)
			if pts.size() >= 3:
				result.subs_last.append(pts)

	return result


# Layer où le PatternShapeTool posera la prochaine forme. null si indéterminable.
func _get_pattern_target_layer():
	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null: return null
	var al = pat_tool.get("ActiveLayer")
	if al == null: return null
	return int(al)


# Le nœud est-il strictement SOUS le layer-cible ? Faux si min_layer est null ou
# si le layer du nœud est indéterminable (on garde alors la barrière par sécurité).
# Lecture du calque alignée sur path_fix : GetLayer() si dispo (patterns), sinon
# _effective_z() (murs/paths — un Pathway n'expose PAS GetLayer/layer, il faut
# sommer les z_index le long de la chaîne parente).
func _is_below_layer(node, min_layer) -> bool:
	if min_layer == null: return false
	if not (node is CanvasItem): return false
	var l = node.GetLayer() if node.has_method("GetLayer") else _effective_z(node)
	return int(l) < min_layer


# z effectif d'un CanvasItem : somme des z_index le long de la chaîne parente tant
# que z_as_relative est vrai (modèle DD : sous-conteneurs z_as_relative=true qui
# héritent du z de la couche). Comparable à PatternShapeTool.ActiveLayer
# (= prop.ZIndex assigné à la création).
func _effective_z(ci) -> int:
	var z = 0
	var n = ci
	while n != null and n is CanvasItem:
		z += n.z_index
		if not n.z_as_relative:
			break
		n = n.get_parent()
	return z


# Offsette CHAQUE segment de la polyline en rectangle convexe (END_SQUARE) et
# l'ajoute aux barriers à soustraire. Robuste aux auto-intersections : des
# rectangles simples ne génèrent jamais de "trou de remplissage" Clipper au
# croisement (contrairement à un offset global d'une bande auto-intersectante).
# END_SQUARE fait dépasser chaque rectangle de BARRIER_THICKNESS → les segments
# consécutifs se recouvrent aux sommets et scellent les coins.
# Si `closed`, le segment de fermeture (dernier → premier) est inclus.
func _append_segment_quads(pts: Array, closed: bool, out: Dictionary):
	var n = pts.size()
	if n < 2: return
	var seg_count = n if closed else n - 1
	for i in range(seg_count):
		var a = pts[i]
		var b = pts[(i + 1) % n]
		if a.distance_to(b) < 0.01:
			continue
		var seg_offset = Geometry.offset_polyline_2d([a, b], BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_SQUARE)
		for poly in seg_offset:
			if poly.size() >= 3:
				out.subs_last.append(_to_array(poly))


# La polyline se croise-t-elle elle-même ? Teste chaque paire de segments non
# adjacents. O(N²), suffisant pour des murs. Si `closed`, inclut le segment de
# fermeture et traite premier/dernier segments comme adjacents.
func _polyline_self_intersects(pts: Array, closed: bool) -> bool:
	var n = pts.size()
	if n < 4: return false
	var seg_count = n if closed else n - 1
	for i in range(seg_count):
		var a1 = pts[i]
		var a2 = pts[(i + 1) % n]
		for j in range(i + 1, seg_count):
			if j == i + 1:
				continue  # segments adjacents : partagent un sommet
			if closed and i == 0 and j == seg_count - 1:
				continue  # fermeture adjacente au premier segment
			var b1 = pts[j]
			var b2 = pts[(j + 1) % n]
			if Geometry.segment_intersects_segment_2d(a1, a2, b1, b2) != null:
				return true
	return false


func _classify_polyline_barrier(pts: Array, loop: bool, out: Dictionary):
	if pts.size() < 2: return

	# Détection de duplicate closing point (commune aux paths Loop=true avec
	# duplicate et aux polylines fermées par coïncidence)
	if pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) < 2.0:
		pts.pop_back()
		loop = true
	if pts.size() < 2: return

	if not loop:
		# Polyline ouverte : snap endpoints au bord de map.
		pts[0] = _snap_endpoint_to_map_edge(pts[0], EDGE_SNAP_THRESHOLD)
		pts[pts.size() - 1] = _snap_endpoint_to_map_edge(pts[pts.size() - 1], EDGE_SNAP_THRESHOLD)
		# Bande unique : 1 barrière au lieu d'1 quad par segment. C'est LE levier de
		# perf : un path courbe a des centaines de points interpolés → autant de
		# clips Clipper avec le découpage par segment. On ne retombe sur ce découpage
		# (robuste aux croisements) que si la polyline se croise vraiment.
		if pts.size() <= SELF_INTERSECT_CHECK_MAX and _polyline_self_intersects(pts, false):
			_append_segment_quads(pts, false, out)
		else:
			var strip = Geometry.offset_polyline_2d(pts, BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_SQUARE)
			for poly in strip:
				if poly.size() >= 3:
					out.subs_last.append(_to_array(poly))
		return

	# Loop qui se croise lui-même (plusieurs cellules tracées par un seul mur,
	# ex. une grille de pièces) : l'offset global END_JOINED ne renvoie qu'un
	# couple outer/inner et ne sépare pas les cellules internes — on ne peut
	# remplir qu'une cellule. On retombe sur la soustraction par segment, qui
	# produit une subdivision planaire complète → chaque cellule devient sa
	# propre région remplissable.
	if _polyline_self_intersects(pts, true):
		_append_segment_quads(pts, true, out)
		return

	# Polyline fermée simple : offset extérieur + offset intérieur
	var offset_result = Geometry.offset_polyline_2d(pts, BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_JOINED)
	var polys = []
	for b in offset_result:
		if b.size() >= 3:
			polys.append(_to_array(b))
	if polys.size() == 0:
		return
	if polys.size() == 1:
		# Anneau dégénéré (intérieur collapsé sur mur trop fin) : juste soustraire
		out.closed_pairs.append({"outer": polys[0], "inner": null})
		return
	# Plus gros = offset extérieur (à soustraire), plus petit = intérieur (à ajouter)
	var i_big := 0
	var i_small := 1
	if _polygon_area(polys[1]) > _polygon_area(polys[0]):
		i_big = 1; i_small = 0
	out.closed_pairs.append({"outer": polys[i_big], "inner": polys[i_small]})
	# Polygones supplémentaires (auto-intersection rare) : soustractions sans inner
	for i in range(polys.size()):
		if i == i_big or i == i_small: continue
		out.closed_pairs.append({"outer": polys[i], "inner": null})


# ── Bridge cut : extérieur + trou → polygone simple ──────────────────────────

# Splice un trou dans un polygone extérieur via une "coupe invisible" : on relie
# le sommet de `outer` le plus proche d'un sommet de `hole`, on parcourt le trou,
# puis on revient. Les deux arêtes du pont se superposent (aire nulle).
# Les windings de outer et hole doivent être opposés.
func _build_bridged_polygon(outer: Array, hole: Array) -> Array:
	var h = []
	for p in hole: h.append(p)
	if Geometry.is_polygon_clockwise(outer) == Geometry.is_polygon_clockwise(h):
		h.invert()

	var bi := 0
	var bj := 0
	var bd := INF
	for i in range(outer.size()):
		for j in range(h.size()):
			var d = outer[i].distance_squared_to(h[j])
			if d < bd:
				bd = d; bi = i; bj = j

	var out = []
	for k in range(bi + 1):
		out.append(outer[k])
	var n = h.size()
	for k in range(n + 1):
		out.append(h[(bj + k) % n])
	out.append(outer[bi])
	for k in range(bi + 1, outer.size()):
		out.append(outer[k])
	return out


# ── Multi-trous : splice tous les trous en étoile depuis l'outer ─────────────
# Le bridge cut itératif (chaque trou bridgé dans le résultat du précédent)
# fait croiser des bridges quand les trous sont nombreux ou proches. Ici chaque
# trou est connecté DIRECTEMENT à l'outer original avec un bridge qui évite
# explicitement de traverser les autres trous. On splice ensuite tous les
# bridges en une seule passe en parcourant l'outer.
func _bridge_holes_into_outer(outer: Array, holes: Array) -> Array:
	if holes.size() == 0:
		return outer

	var outer_cw = Geometry.is_polygon_clockwise(outer)

	# Préparer chaque trou avec winding opposé à l'outer
	var prepared = []
	for h in holes:
		var h_pts = []
		for p in h: h_pts.append(p)
		if Geometry.is_polygon_clockwise(h_pts) == outer_cw:
			h_pts.invert()
		prepared.append(h_pts)

	# Pour chaque trou : pont par PROJECTION du sommet le plus proche sur la
	# frontière (arête) de outer. Donne un pont court et perpendiculaire à outer,
	# au lieu d'une longue diagonale entre sommets. Moins de risque que des clips
	# ultérieurs (path, autres murs) coupent le pont et créent des frontières
	# fantômes le long de la trajectoire diagonale.
	var bridges = []
	for h_idx in range(prepared.size()):
		var info = _find_projection_bridge(outer, prepared[h_idx])
		bridges.append(info)

	# Trier par (edge_idx, t) pour traverser outer en un seul passage. Plusieurs
	# ponts sur la même arête sont spliçés par ordre de t croissant.
	bridges.sort_custom(self, "_sort_bridges_by_edge_and_t")

	var result = []
	var b_idx = 0
	for i in range(outer.size()):
		result.append(outer[i])
		while b_idx < bridges.size() and bridges[b_idx].edge_idx == i:
			var b = bridges[b_idx]
			# Insère le point de pont (projection sur l'arête outer[i]→outer[i+1])
			result.append(b.bridge_pt)
			# Parcourt le trou en cycle complet depuis hi
			var h_pts = b.hole
			var n = h_pts.size()
			for k in range(n + 1):
				result.append(h_pts[(b.hi + k) % n])
			# Revient au point de pont (arête coincidente avec celle d'entrée)
			result.append(b.bridge_pt)
			b_idx += 1
	return result


# Trouve le pont de longueur minimale entre la frontière d'outer et un sommet
# de hole. Pour chaque sommet de hole, calcule sa projection sur chaque arête
# d'outer. Retourne la projection la plus proche.
func _find_projection_bridge(outer: Array, hole: Array) -> Dictionary:
	var best_d := INF
	var best_hi := 0
	var best_edge_idx := 0
	var best_t := 0.0
	var best_bridge_pt := Vector2.ZERO
	var n_out = outer.size()
	for h_idx in range(hole.size()):
		var h_pt: Vector2 = hole[h_idx]
		for e_idx in range(n_out):
			var a: Vector2 = outer[e_idx]
			var b: Vector2 = outer[(e_idx + 1) % n_out]
			var ab = b - a
			var len_sq = ab.length_squared()
			if len_sq < 0.001: continue
			var t = clamp(ab.dot(h_pt - a) / len_sq, 0.0, 1.0)
			var proj = a + ab * t
			var d = h_pt.distance_squared_to(proj)
			if d < best_d:
				best_d = d
				best_hi = h_idx
				best_edge_idx = e_idx
				best_t = t
				best_bridge_pt = proj
	return {
		"hi": best_hi,
		"edge_idx": best_edge_idx,
		"t": best_t,
		"bridge_pt": best_bridge_pt,
		"hole": hole,
	}


func _sort_bridges_by_edge_and_t(a, b) -> bool:
	if a.edge_idx != b.edge_idx:
		return a.edge_idx < b.edge_idx
	return a.t < b.t


# Le segment p1-p2 traverse-t-il l'intérieur du polygone ? On ignore les
# intersections aux endpoints (un bridge peut légitimement toucher la frontière
# d'un autre trou en ses propres extrémités, mais ne doit pas la traverser).
# (Plus utilisé par le bridge projection-based, conservé pour référence.)
func _segment_crosses_polygon(p1: Vector2, p2: Vector2, polygon: Array) -> bool:
	var n = polygon.size()
	if n < 3: return false
	for i in range(n):
		var q1 = polygon[i]
		var q2 = polygon[(i + 1) % n]
		var inter = Geometry.segment_intersects_segment_2d(p1, p2, q1, q2)
		if inter == null: continue
		if inter.distance_squared_to(p1) > 1.0 and inter.distance_squared_to(p2) > 1.0:
			return true
	return false


# ── Calcul de la région à remplir ────────────────────────────────────────────
# Pipeline :
#   1. Pour chaque mur fermé simple (trié par aire extérieure DÉCROISSANTE) :
#        - soustraire son offset extérieur (retire mur+pièce)
#        - ajouter son offset intérieur (réintroduit la pièce comme région à part)
#   2. Soustraire les barrières "subs_last" : polylines ouvertes, loops
#      auto-intersectants (rectangles par segment) et patterns.
#
# Après CHAQUE soustraction on recombine via _combine_outer_holes : les trous
# sont pontés dans leur outer pour reformer un polygone simple. C'est nécessaire
# pour la topologie : le clip suivant opère alors sur un anneau unique incluant
# les trous précédents comme fentes, ce qui permet de détacher correctement les
# pièces fermées (cellules) au fur et à mesure. Le pontage utilise earcut
# (_eliminate_holes), qui produit des ponts non-croisants — contrairement à
# l'ancien pontage par projection qui pouvait générer des polygones
# auto-intersectants refusés par DrawPolygon ("Bad Polygon").
func _compute_region(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool, progress = null) -> Dictionary:
	var map_rect = _get_map_bounds_polygon()
	if map_rect.size() < 3:
		return {"outer": [], "holes": [], "cancelled": false}
	var tree = _g.Editor.get_tree()
	# 0–20 % : lecture/offset des barrières ; 20–90 % : fenêtre + union ;
	# 90 % : extraction ; 95–100 % posés par _do_fill (création du pattern).
	var solids = _build_barrier_solids(stop_walls, stop_paths, stop_patterns, progress, tree, 0.0, 0.2)
	if solids is GDScriptFunctionState:
		solids = yield(solids, "completed")
	if solids == null:
		return {"outer": [], "holes": [], "cancelled": true}
	var solid_bbs = []
	for spoly in solids:
		solid_bbs.append(_aabb(spoly.outer))
	var map_bb = _aabb(map_rect)
	var eps = 1.0
	var half = _initial_half_extent()
	var box = Rect2(mouse_world - half, half * 2.0).clip(map_bb)
	var out_outer = []
	var out_holes = []
	var iter = 0
	# Union INCRÉMENTALE entre agrandissements de fenêtre : l'union étant
	# commutative/associative, on repart des composantes déjà fusionnées et on
	# n'ajoute que les nouveaux solides entrés dans la boîte — le coût total
	# est celui d'UNE seule union (plus des re-fusions marginales), au lieu de
	# tout refusionner à chaque doublement. La progression publiée est la
	# fraction de solides intégrés, affinée par les fusions dans
	# _union_components — plus de saut 0→90 % ni de plateau.
	var included = {}
	var comps = []
	while true:
		iter += 1
		var full = _rect_covers(box, map_bb, eps)
		var frac_before = float(included.size()) / max(1.0, float(solids.size()))
		var added = 0
		for i in range(solids.size()):
			if included.has(i): continue
			if solid_bbs[i].intersects(box):
				included[i] = true
				comps.append(_solid_to_comp(solids[i]))
				added += 1
		var frac_now = float(included.size()) / max(1.0, float(solids.size()))
		if progress != null and progress.pump():
			progress.set_progress(0.2 + 0.7 * frac_before, "Computing fill region\u2026")
			yield(tree, "idle_frame")
			if progress.cancelled:
				return {"outer": [], "holes": [], "cancelled": true}
		if added > 0:
			var merged = _union_components(comps, progress, tree, 0.2 + 0.7 * frac_before, 0.2 + 0.7 * frac_now)
			if merged is GDScriptFunctionState:
				merged = yield(merged, "completed")
			if merged == null:
				return {"outer": [], "holes": [], "cancelled": true}
			comps = merged
		var pool = _flatten_pool(comps)
		var res = _extract_click_region(pool, map_rect, mouse_world)
		if res.kind == "room":
			# N'accepter la pièce que si elle tient entièrement DANS la fenêtre :
			# une pièce qui atteint un bord intérieur de la boîte peut ignorer des
			# barrières (cloisons/îlots) situées plus loin dans la pièce, dont
			# l'AABB ne touche pas encore la boîte → il faut étendre et réessayer.
			var rb = _aabb(res.outer)
			if full or not _touches_interior_edge(rb, box, map_bb, eps):
				out_outer = res.outer
				out_holes = res.holes
				break
		elif res.kind == "wall":
			out_outer = []
			out_holes = []
			break
		else:
			if full:
				out_outer = res.outer
				out_holes = res.holes
				break
		if full or iter > 24:
			break
		var c = box.position + box.size * 0.5
		var ns = box.size * 2.0
		box = Rect2(c - ns * 0.5, ns).clip(map_bb)
	if progress != null:
		progress.set_progress(0.9, "Extracting region\u2026")
		yield(tree, "idle_frame")
		if progress.cancelled:
			return {"outer": [], "holes": [], "cancelled": true}
	if out_outer.size() < 3:
		return {"outer": [], "holes": [], "cancelled": false}
	return {"outer": out_outer, "holes": out_holes, "cancelled": false}


func _initial_half_extent() -> Vector2:
	var world = _g.get("World") if _g != null else null
	if world != null:
		var cs = world.get("GridCellSize")
		if cs != null:
			return cs * 3.0
	var mb = _aabb(_get_map_bounds_polygon())
	return mb.size * 0.1 + Vector2(1, 1)


# Ne conserve que les morceaux de région contenant le clic (au plus un, morceaux
# disjoints). Si aucun ne le contient (transitoire : clic dans un trou en attente
# d'un inner ré-ajouté), on ne prune pas — on garde tout par sécurité.
func _keep_click_piece(regions: Array, region_bbs: Array, mouse_world: Vector2) -> Dictionary:
	# Prune par AABB uniquement : on ne jette qu'un morceau dont la boîte englobante
	# ne contient PAS le clic — toujours sûr (le clic lui est extérieur, et une
	# soustraction ne fait que rétrécir/jamais fusionner). INDÉPENDANT DE L'ORDRE.
	# (Ne PAS utiliser _point_in_polygon ici : les murs ouverts créent des polygones
	# à bridge-cuts sur lesquels le test even-odd est peu fiable → jetait parfois le
	# vrai morceau du clic, résultat dépendant de l'ordre des murs.)
	var kr = []
	var kb = []
	for i in range(regions.size()):
		if region_bbs[i].grow(1.0).has_point(mouse_world):
			kr.append(regions[i])
			kb.append(region_bbs[i])
	if kr.size() > 0:
		return {"regions": kr, "bbs": kb}
	return {"regions": regions, "bbs": region_bbs}


func _rect_to_poly(r: Rect2) -> Array:
	return [r.position, r.position + Vector2(r.size.x, 0), r.end, r.position + Vector2(0, r.size.y)]


func _rect_covers(box: Rect2, map_bb: Rect2, eps: float) -> bool:
	return box.position.x <= map_bb.position.x + eps and box.position.y <= map_bb.position.y + eps \
		and box.end.x >= map_bb.end.x - eps and box.end.y >= map_bb.end.y - eps


func _touches_interior_edge(rb: Rect2, box: Rect2, map_bb: Rect2, eps: float) -> bool:
	if box.position.x > map_bb.position.x + eps and rb.position.x <= box.position.x + eps:
		return true
	if box.end.x < map_bb.end.x - eps and rb.end.x >= box.end.x - eps:
		return true
	if box.position.y > map_bb.position.y + eps and rb.position.y <= box.position.y + eps:
		return true
	if box.end.y < map_bb.end.y - eps and rb.end.y >= box.end.y - eps:
		return true
	return false


func _sort_closed_pairs_by_outer_area_desc(a, b) -> bool:
	return _polygon_area(a.outer) > _polygon_area(b.outer)


# Soustrait un barrier de chaque polygone du pool, puis recombine les outers +
# trous retournés par Clipper en polygones simples-avec-trou (bridge cut earcut).
# Le résultat est un pool de polygones simples ré-injectables dans la soustraction
# suivante : le clip suivant voit les trous précédents comme des fentes, ce qui
# permet de détacher les pièces fermées (cellules) progressivement.
func _subtract_and_combine(regions: Array, region_bbs: Array, barrier: Array) -> Dictionary:
	var new_regions = []
	var new_bbs = []
	var bb = _aabb(barrier).grow(1.0)
	for ri in range(regions.size()):
		var r = regions[ri]
		var r_bb = region_bbs[ri]
		# Rejet broad-phase : si l'AABB du barrier ne touche pas celle de la région,
		# le clip ne retirerait rien → on garde la région telle quelle sans Clipper.
		if not r_bb.intersects(bb):
			new_regions.append(r)
			new_bbs.append(r_bb)
			continue
		var clipped = Geometry.clip_polygons_2d(r, barrier)
		var combined = _combine_outer_holes(clipped)
		for c in combined:
			if c.size() >= 3:
				var cc = _to_array(c)
				new_regions.append(cc)
				new_bbs.append(_aabb(cc))
	return {"regions": new_regions, "bbs": new_bbs}


func _aabb(poly: Array) -> Rect2:
	if poly.size() == 0:
		return Rect2()
	var r = Rect2(poly[0], Vector2.ZERO)
	for i in range(1, poly.size()):
		r = r.expand(poly[i])
	return r


# Prend la sortie brute de clip_polygons_2d (peut contenir des paires outer+hole
# imbriquées) et la recombine en polygones simples-avec-trou via bridge cut.
# Utilise une classification par profondeur dans la hiérarchie de containment :
#   - profondeur paire = polygone "outer" (région filled)
#   - profondeur impaire = polygone "hole" (trou de son parent immédiat)
# Cela gère correctement les nestings arbitraires : un outer dans un trou est
# une nouvelle région à part, pas un trou de plus.
func _combine_outer_holes(polygons_pool: Array) -> Array:
	var polys = []
	for p in polygons_pool:
		if p.size() >= 3:
			polys.append(_to_array(p))
	if polys.size() <= 1:
		return polys

	# Parent immédiat de chaque polygone = plus petit polygone le contenant
	var parents = []
	for i in range(polys.size()):
		parents.append(_find_immediate_parent_idx(i, polys))

	# Profondeur dans la hiérarchie
	var depths = []
	for i in range(polys.size()):
		var d = 0
		var p_idx = parents[i]
		while p_idx >= 0:
			d += 1
			p_idx = parents[p_idx]
		depths.append(d)

	# Outers (profondeur paire) avec leurs trous immédiats (profondeur impaire, parent = cet outer)
	var result = []
	for i in range(polys.size()):
		if depths[i] % 2 != 0: continue  # skip holes
		var outer = polys[i]
		var outer_holes = []
		for j in range(polys.size()):
			if depths[j] % 2 == 0: continue  # skip outers
			if parents[j] == i:
				outer_holes.append(polys[j])
		if outer_holes.size() == 0:
			result.append(outer)
		else:
			result.append(_eliminate_holes(outer, outer_holes))
	return result


# ── Élimination de trous robuste (façon earcut) ──────────────────────────────
# Convertit un outer + N trous en UN seul polygone simple non auto-intersectant.
# Le pont de chaque trou relie son sommet le plus à gauche à un sommet VISIBLE de
# l'outer (rayon vers la gauche + raffinement par sommets réflexes), ce qui
# garantit des ponts qui ne se croisent pas — contrairement au pontage par
# projection qui, avec beaucoup de trous, produisait des polygones
# auto-intersectants refusés par DrawPolygon ("Bad Polygon").
# Tout le calcul se fait en coords y-inversées (convention math d'earcut : outer
# CCW / trous CW), puis on ré-inverse le résultat.
func _eliminate_holes(outer_in: Array, holes_in: Array) -> Array:
	if holes_in.size() == 0:
		return outer_in
	var outer = _flip_y(outer_in)
	if _ring_signed_area(outer) < 0.0:
		outer.invert()  # outer en CCW (aire signée positive)
	var prepared = []
	for h in holes_in:
		var hp = _flip_y(h)
		if _ring_signed_area(hp) > 0.0:
			hp.invert()  # trous en CW (aire signée négative)
		prepared.append(hp)
	prepared.sort_custom(self, "_sort_rings_by_leftmost_x")
	for hole in prepared:
		outer = _eliminate_hole(outer, hole)
	return _flip_y(outer)


func _flip_y(ring: Array) -> Array:
	var r = []
	for p in ring:
		r.append(Vector2(p.x, -p.y))
	return r


func _ring_signed_area(ring: Array) -> float:
	var a = 0.0
	var n = ring.size()
	for i in range(n):
		var j = (i + 1) % n
		a += ring[i].x * ring[j].y - ring[j].x * ring[i].y
	return a * 0.5


func _sort_rings_by_leftmost_x(a, b) -> bool:
	return _ring_min_x(a) < _ring_min_x(b)


func _ring_min_x(ring: Array) -> float:
	var mx = INF
	for p in ring:
		if p.x < mx: mx = p.x
	return mx


func _eliminate_hole(outer: Array, hole: Array) -> Array:
	var hi = 0
	var minx = INF
	for i in range(hole.size()):
		if hole[i].x < minx:
			minx = hole[i].x
			hi = i
	var bi = _find_hole_bridge(outer, hole, hi)
	if bi < 0:
		# Repli : sommet le plus proche (peut se croiser mais évite tout crash)
		var bd = INF
		bi = 0
		for i in range(outer.size()):
			var d = outer[i].distance_squared_to(hole[hi])
			if d < bd:
				bd = d; bi = i
	# Splice : outer[0..bi] + boucle complète du trou depuis hi + retour outer[bi]
	var res = []
	for k in range(bi + 1):
		res.append(outer[k])
	var n = hole.size()
	for k in range(n + 1):
		res.append(hole[(hi + k) % n])
	res.append(outer[bi])
	for k in range(bi + 1, outer.size()):
		res.append(outer[k])
	return res


func _signed_area3(p: Vector2, q: Vector2, r: Vector2) -> float:
	return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)


func _point_in_triangle(a: Vector2, b: Vector2, c: Vector2, p: Vector2) -> bool:
	return (c.x - p.x) * (a.y - p.y) - (a.x - p.x) * (c.y - p.y) >= 0.0 and \
		(a.x - p.x) * (b.y - p.y) - (b.x - p.x) * (a.y - p.y) >= 0.0 and \
		(b.x - p.x) * (c.y - p.y) - (c.x - p.x) * (b.y - p.y) >= 0.0


func _locally_inside(outer: Array, ai: int, b: Vector2) -> bool:
	var n = outer.size()
	var a = outer[ai]
	var aprev = outer[(ai - 1 + n) % n]
	var anext = outer[(ai + 1) % n]
	if _signed_area3(aprev, a, anext) < 0.0:
		return _signed_area3(a, b, anext) >= 0.0 and _signed_area3(a, aprev, b) >= 0.0
	else:
		return _signed_area3(a, b, aprev) < 0.0 or _signed_area3(a, anext, b) < 0.0


# Port d'earcut findHoleBridge : trouve l'index du sommet de `outer` auquel relier
# le sommet `hi` (le plus à gauche) de `hole`. Retourne -1 si rien trouvé.
func _find_hole_bridge(outer: Array, hole: Array, hi: int) -> int:
	var hx = hole[hi].x
	var hy = hole[hi].y
	var qx = -INF
	var m = -1
	var n = outer.size()
	# Rayon horizontal vers la gauche : arête traversée, endpoint de x max <= hx
	for i in range(n):
		var p = outer[i]
		var pnext = outer[(i + 1) % n]
		if hy <= p.y and hy >= pnext.y and pnext.y != p.y:
			var x = p.x + (hy - p.y) * (pnext.x - p.x) / (pnext.y - p.y)
			if x <= hx and x > qx:
				qx = x
				m = i if p.x < pnext.x else (i + 1) % n
				if x == hx:
					return m
	if m < 0:
		return -1
	# Raffinement : parmi les sommets réflexes dans le triangle (hole, intersection,
	# m), choisir celui de tangente minimale et localement visible.
	var mx = outer[m].x
	var my = outer[m].y
	var tan_min = INF
	var best = m
	for i in range(n):
		var pv = outer[i]
		if hx >= pv.x and pv.x >= mx and hx != pv.x:
			var a: Vector2
			var c: Vector2
			if hy < my:
				a = Vector2(hx, hy); c = Vector2(qx, hy)
			else:
				a = Vector2(qx, hy); c = Vector2(hx, hy)
			if _point_in_triangle(a, Vector2(mx, my), c, pv):
				var tanv = abs(hy - pv.y) / (hx - pv.x)
				if (tanv < tan_min or (tanv == tan_min and pv.x > outer[best].x)) and _locally_inside(outer, i, hole[hi]):
					best = i
					tan_min = tanv
	return best


func _find_immediate_parent_idx(p_idx: int, polygons: Array) -> int:
	var p_area = _polygon_area(polygons[p_idx])
	var min_parent_area = INF
	var min_parent_idx = -1
	for q_idx in range(polygons.size()):
		if q_idx == p_idx: continue
		var q_area = _polygon_area(polygons[q_idx])
		if q_area <= p_area: continue  # un parent doit être plus gros que son enfant
		if not _polygon_inside_polygon(polygons[p_idx], polygons[q_idx]): continue
		if q_area < min_parent_area:
			min_parent_area = q_area
			min_parent_idx = q_idx
	return min_parent_idx


# ── Création du pattern shape ────────────────────────────────────────────────

func _draw_pattern_poly(ps_node, pts: Array, invert: bool, rot: float) -> bool:
	var node_id = _g.World.nextNodeID
	ps_node.DrawPolygon(pts, invert)
	if _g.World.HasNodeID(node_id):
		var shape = _g.World.GetNodeByID(node_id)
		if shape.has_method("SetNewRotation"):
			shape.SetNewRotation(rot)
		_g.World.AssignNodeID(shape)
		return true
	return false


# Dédoublonne les sommets consécutifs et supprime les « darts » (pointes de
# largeur nulle : le contour part et revient sur la même direction), artefacts
# des fusions Clipper des quads de segments. Ne modifie pas la forme utile.
func _clean_ring_basic(poly: Array) -> Array:
	var pts = []
	for p in poly:
		if pts.size() == 0 or pts[pts.size() - 1].distance_to(p) > 0.03:
			pts.append(p)
	while pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) <= 0.03:
		pts.pop_back()
	var changed = true
	while changed and pts.size() >= 3:
		changed = false
		var n = pts.size()
		for i in range(n):
			var b = pts[i]
			var ab = (pts[(i - 1 + n) % n] - b)
			var cb = (pts[(i + 1) % n] - b)
			if ab.length() < 0.03 or cb.length() < 0.03:
				pts.remove(i)
				changed = true
				break
			# pointe : les deux arêtes repartent quasi dans la même direction
			if ab.normalized().dot(cb.normalized()) > 0.999:
				pts.remove(i)
				changed = true
				break
	return pts


# Décompose un anneau qui repasse par (quasi) le même sommet — pincement,
# artefact fréquent des fusions Clipper — en sous-anneaux strictement simples.
func _split_pinched_ring(pts: Array) -> Array:
	var n = pts.size()
	if n < 3: return []
	for i in range(n):
		for j in range(i + 2, n):
			if i == 0 and j == n - 1: continue
			if pts[i].distance_to(pts[j]) <= 0.03:
				var r1 = []
				for k in range(i, j): r1.append(pts[k])
				var r2 = []
				for k in range(j, n): r2.append(pts[k])
				for k in range(0, i): r2.append(pts[k])
				return _split_pinched_ring(r1) + _split_pinched_ring(r2)
	return [pts]


# Nettoie un anneau et le rend triangulable : dédoublonnage + darts, et si la
# triangulation échoue encore, décomposition des pincements en lobes (chaque
# lobe sera dessiné comme un pattern à part — une région pincée EST deux zones
# reliées par un point). Renvoie la liste des anneaux exploitables.
func _ring_to_lobes(poly: Array) -> Array:
	var c = _clean_ring_basic(poly)
	if c.size() < 3: return []
	if Geometry.triangulate_polygon(PoolVector2Array(c)).size() >= 3:
		return [c]
	var lobes = []
	for r in _split_pinched_ring(c):
		var rc = _clean_ring_basic(r)
		if rc.size() >= 3 and _polygon_area(rc) > 1.0 \
				and Geometry.triangulate_polygon(PoolVector2Array(rc)).size() >= 3:
			lobes.append(rc)
	if lobes.size() == 0:
		lobes = [c]  # dernier recours : DrawPolygon avertira
	return lobes


func _create_pattern_at(points: Array, holes: Array = [], click_pt = null):
	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null: return

	var level = _get_current_level()
	if level == null: return
	var ps_node = level.get("PatternShapes")
	if ps_node == null: return

	# Rotation courante du tool. On l'applique via SetNewRotation (qui ne touche
	# NI la texture NI la couleur), pas via SetOptions.
	var rotation_val = 0.0
	var rot_ctrl = pat_tool.get("Rotation")
	if rot_ctrl != null and rot_ctrl.has_method("get_value"):
		rotation_val = deg2rad(rot_ctrl.get_value())

	# DrawPolygon hérite de la texture/couleur/rotation COURANTES du tool. Les
	# anneaux issus de Clipper peuvent être « faiblement simples » (darts,
	# pincements) : nettoyés/décomposés en lobes triangulables. Les trous sont
	# PONTÉS dans leur lobe via _eliminate_holes (ponts earcut non-croisants).
	# NE PAS utiliser DrawPolygon(h, invertAction=true) : PatternShapes.AddPolygon
	# IGNORE ce flag (la découpe vit dans PatternShapeTool) → chaque « trou »
	# créait un 2e pattern PLEIN par-dessus.
	var lobes = _ring_to_lobes(points)
	if lobes.size() == 0:
		print("[PatternPaintBucket] Erreur: région dégénérée")
		return
	var parts = []
	for l in lobes:
		parts.append({"outer": l, "holes": []})
	for h in holes:
		for hl in _ring_to_lobes(h):
			var cen = _ring_centroid(hl)
			for part in parts:
				if _point_in_polygon(cen, part.outer):
					part.holes.append(hl)
					break
	var made = 0
	var total_holes = 0
	for part in parts:
		var poly = part.outer
		if part.holes.size() > 0:
			poly = _eliminate_holes(part.outer, part.holes)
		if _draw_pattern_poly(ps_node, poly, false, rotation_val):
			made += 1
			total_holes += part.holes.size()
	if made == 0:
		print("[PatternPaintBucket] Erreur: impossible de créer le pattern")
		return
	print("[PatternPaintBucket] Pattern créé : %d forme(s), %d trou(s) ponté(s)" % [made, total_holes])


# ── Fill ─────────────────────────────────────────────────────────────────────

func _do_fill(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool):
	if _filling:
		return
	_filling = true
	var progress = _new_progress("Filling pattern…")
	if progress != null:
		# Yield une frame pour que le 0 % soit réellement AFFICHÉ (sinon la
		# première frame rendue arrive au premier pump(), déjà à quelques %).
		progress.set_progress(0.0, "Computing fill region\u2026")
		yield(_g.Editor.get_tree(), "idle_frame")
	var t_start = OS.get_ticks_msec()

	var region = _compute_region(mouse_world, stop_walls, stop_paths, stop_patterns, progress)
	if region is GDScriptFunctionState:
		region = yield(region, "completed")

	if progress != null and region.get("cancelled") == true:
		progress.close()
		print("[PatternPaintBucket] Remplissage annulé par l'utilisateur")
		_filling = false
		return

	var t_compute = OS.get_ticks_msec() - t_start
	if region.outer.size() < 3:
		if progress != null: progress.close()
		print("[PatternPaintBucket] Aucune région trouvée (clic sur un mur ?) — %d ms" % t_compute)
		_filling = false
		return

	if progress != null:
		# Jalon rendu avant le pontage + DrawPolygon.
		progress.set_progress(0.95, "Creating pattern\u2026")
		yield(_g.Editor.get_tree(), "idle_frame")

	print("[PatternPaintBucket] Région : %d points — calcul %d ms" % [region.outer.size(), t_compute])
	_create_pattern_at(region.outer, region.get("holes", []), mouse_world)
	if progress != null:
		# Deux frames pour que le 100 % soit visible avant fermeture.
		progress.set_progress(1.0, "Done")
		yield(_g.Editor.get_tree(), "idle_frame")
		yield(_g.Editor.get_tree(), "idle_frame")
		progress.close()
	_filling = false


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_input(event) -> bool:
	if not _bucket_active: return false
	if not _is_pattern_tool_active(): return false
	if not (event is InputEventMouseButton): return false
	if not event.pressed: return false
	if event.button_index != BUTTON_LEFT: return false

	if ui_util != null and ui_util.is_mouse_over_hud(input_listener):
		return false

	var world_ui = _g.get("WorldUI")
	if world_ui == null: return false
	var canvas_xform = world_ui.get_viewport().get_canvas_transform()
	var mouse_world: Vector2 = canvas_xform.affine_inverse().xform(event.position)

	var stop_walls = _cb_walls.pressed if _cb_walls != null else true
	var stop_paths = _cb_paths.pressed if _cb_paths != null else true
	var stop_patterns = _cb_patterns.pressed if _cb_patterns != null else false
	_do_fill(mouse_world, stop_walls, stop_paths, stop_patterns)
	return true


# ── Update ────────────────────────────────────────────────────────────────────

func update(_delta):
	if _bucket_button == null: return

	if _bucket_active and not _is_pattern_tool_active():
		_remove_cursor()
		_saved_cursor_mode = -1
		return

	if _bucket_active and _is_pattern_tool_active():
		_hide_preview()
		# Seau uniquement sur le canvas ; souris normale au-dessus de l'UI (menus,
		# panneaux, floatbar, popups). On peut peindre partout, donc plus de curseur
		# « croix » et plus de test de zone fillable.
		if ui_util != null and ui_util.is_mouse_over_hud(input_listener):
			_remove_cursor()
		else:
			if not _cursor_applied:
				_apply_cursor()

	if _bucket_active:
		var pat_tool = _g.Editor.Tools["PatternShapeTool"]
		if pat_tool != null:
			var ep = pat_tool.get("EditPoints")
			if ep != null and ep.get("pressed") == true:
				_bucket_active = false
				_bucket_button.pressed = false
				_remove_cursor()
				_show_preview()
				return

	if _bucket_active:
		for btn in _shape_buttons:
			if is_instance_valid(btn) and btn.pressed:
				_bucket_active = false
				_bucket_button.pressed = false
				_remove_cursor()
				_show_preview()
				return


# Si `progress` est fourni : publie la lecture des barrières sur [p_from, p_to]
# et pompe l'UI (yield) — c'était la phase silencieuse responsable du saut
# initial de la barre. Renvoie null si annulé ; synchrone sans progress.
func _build_barrier_solids(stop_walls: bool, stop_paths: bool, stop_patterns: bool, progress = null, tree = null, p_from := 0.0, p_to := 0.0):
	var solids = []
	var level = _get_current_level()
	if level == null: return solids
	var min_layer = _get_pattern_target_layer()

	var items = []
	var walls_node = level.get("Walls") if stop_walls else null
	if walls_node != null:
		for child in walls_node.get_children():
			if is_instance_valid(child) and not _is_below_layer(child, min_layer):
				items.append(["wall", child])
	var paths_node = level.get("Pathways") if stop_paths else null
	if paths_node != null:
		for child in paths_node.get_children():
			if is_instance_valid(child) and not _is_below_layer(child, min_layer):
				items.append(["path", child])
	if stop_patterns:
		for shape in _get_all_pattern_shapes():
			if not _is_below_layer(shape, min_layer):
				items.append(["pattern", shape])

	var total = max(1, items.size())
	for idx in range(items.size()):
		var kind = items[idx][0]
		var node = items[idx][1]
		if not is_instance_valid(node): continue
		if kind == "wall":
			var pts_raw = node.get("Points")
			if pts_raw != null and pts_raw.size() >= 2:
				var xform = node.get_global_transform()
				var pts = []
				for pp in pts_raw:
					pts.append(xform.xform(pp))
				_append_barrier_solids(pts, bool(node.get("Loop")), solids)
		elif kind == "path":
			var pts = _get_path_polyline(node)
			if pts.size() >= 2:
				_append_barrier_solids(pts, bool(node.get("Loop")), solids)
		else:
			var pts = _get_pattern_polygon(node)
			if pts.size() >= 3:
				solids.append({"outer": _ensure_ccw(_to_array(pts)), "holes": []})
		if progress != null and progress.pump():
			progress.set_progress(p_from + (p_to - p_from) * float(idx + 1) / float(total), "Reading barriers\u2026 (%d/%d)" % [idx + 1, total])
			yield(tree, "idle_frame")
			if progress.cancelled:
				return null

	return solids


# Simplification Ramer–Douglas–Peucker. Les points lissés (Chaikin) des paths
# sont quasi colinéaires : les décimer avant l'offset réduit fortement la
# taille des polygones manipulés par Clipper (tolérance invisible < 1 px vs
# une bande de ±2 px), donc le coût des fusions sur les grosses maps.
const DECIMATE_EPS = 0.5

func _decimate_polyline(pts: Array, eps: float) -> Array:
	if pts.size() <= 2:
		return pts
	var keep = []
	keep.resize(pts.size())
	for i in range(pts.size()):
		keep[i] = false
	keep[0] = true
	keep[pts.size() - 1] = true
	var stack = [[0, pts.size() - 1]]
	while stack.size() > 0:
		var seg = stack.pop_back()
		var a = seg[0]
		var b = seg[1]
		if b - a < 2: continue
		var pa = pts[a]
		var ab = pts[b] - pa
		var ab_len = ab.length()
		var best_d = -1.0
		var best_i = -1
		for i in range(a + 1, b):
			var d = 0.0
			if ab_len < 0.0001:
				d = pts[i].distance_to(pa)
			else:
				d = abs((pts[i] - pa).cross(ab)) / ab_len
			if d > best_d:
				best_d = d
				best_i = i
		if best_d > eps:
			keep[best_i] = true
			stack.append([a, best_i])
			stack.append([best_i, b])
	var out = []
	for i in range(pts.size()):
		if keep[i]:
			out.append(pts[i])
	return out


# Convertit la sortie d'offset_polyline_2d (anneaux CCW = contours, CW = trous)
# en composantes {outer, holes} ajoutées à `out`. NE PAS retourner les anneaux
# CW en solides : pour un tracé dense qui se recouvre (main levée, boucle
# repassée — >SELF_INTERSECT_CHECK_MAX pts donc branche bande unique), l'offset
# ressort le trou intérieur + des micro-trous entre les passes ; les retourner
# en solides remplissait tout l'intérieur (clic → « wall », erratique).
func _strip_to_components(strip, out: Array):
	var outers = []
	var holes = []
	for poly in strip:
		if poly.size() < 3: continue
		if Geometry.is_polygon_clockwise(poly):
			holes.append(_ensure_ccw(_to_array(poly)))
		else:
			outers.append(_to_array(poly))
	var comps = []
	for o in outers:
		comps.append({"outer": o, "holes": []})
	for h in holes:
		var cen = _ring_centroid(h)
		var best = -1
		var best_a = INF
		for ci in range(comps.size()):
			if not _point_in_polygon(cen, comps[ci].outer): continue
			var oa = _polygon_area(comps[ci].outer)
			if oa < best_a:
				best_a = oa
				best = ci
		if best >= 0:
			comps[best].holes.append(h)
	for c in comps:
		out.append(c)


func _append_barrier_solids(pts_in: Array, loop: bool, solids: Array):
	var pts = []
	for pp in pts_in:
		pts.append(pp)
	if pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) < 2.0:
		pts.pop_back()
		loop = true
	if pts.size() < 2: return
	if pts.size() > 16:
		pts = _decimate_polyline(pts, DECIMATE_EPS)
	if not loop:
		pts[0] = _snap_endpoint_to_map_edge(pts[0], EDGE_SNAP_THRESHOLD)
		pts[pts.size() - 1] = _snap_endpoint_to_map_edge(pts[pts.size() - 1], EDGE_SNAP_THRESHOLD)
		# Bande unique en UN appel Clipper. Depuis que les anneaux CW sont
		# conservés comme trous (_strip_to_components), l'offset est correct
		# même pour un tracé qui se croise : plus besoin du test O(n²) ni du
		# quad-par-segment pour les polylines ouvertes.
		var strip = Geometry.offset_polyline_2d(pts, BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_SQUARE)
		_strip_to_components(strip, solids)
		return
	# Boucle fermée : bande annulaire en UN appel END_JOINED (outer + trou =
	# la pièce enclose, déjà sous la bonne forme pour l'extraction) au lieu
	# d'un quad par segment fusionnés en O(n²) dans _union_components — c'était le
	# point de gel des grosses maps. Repli quads seulement si l'anneau se
	# croise (offset END_JOINED non fiable sur entrée auto-croisée).
	if pts.size() <= SELF_INTERSECT_CHECK_MAX and _polyline_self_intersects(pts, true):
		_append_solid_quads(pts, true, solids)
		return
	var band = Geometry.offset_polyline_2d(pts, BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_JOINED)
	_strip_to_components(band, solids)


func _append_solid_quads(pts: Array, closed: bool, solids: Array):
	var n = pts.size()
	if n < 2: return
	var seg_count = n if closed else n - 1
	for i in range(seg_count):
		var a = pts[i]
		var b = pts[(i + 1) % n]
		if a.distance_to(b) < 0.01: continue
		var seg_offset = Geometry.offset_polyline_2d([a, b], BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_SQUARE)
		_strip_to_components(seg_offset, solids)


func _ensure_ccw(ring: Array) -> Array:
	if Geometry.is_polygon_clockwise(ring):
		var r = ring.duplicate()
		r.invert()
		return r
	return ring


# Convertit un solide {outer, holes} en composante normalisée avec AABB.
func _solid_to_comp(p: Dictionary) -> Dictionary:
	var o = _ensure_ccw(p.outer)
	var hs = []
	for h in p.holes:
		if h.size() >= 3:
			hs.append(_ensure_ccw(h))
	return {"outer": o, "holes": hs, "bb": _aabb(o)}


# Fusionne les composantes jusqu'au point fixe (voir _merge_components pour la
# sémantique trous). Renvoie la liste fusionnée, ou null si annulé. Si
# `progress` est fourni : pompe l'UI et publie une progression réelle basée sur
# les fusions effectuées, mappée sur [p_from, p_to] ; sans progress, purement
# synchrone (aucun yield exécuté).
func _union_components(comps: Array, progress = null, tree = null, p_from := 0.0, p_to := 0.0):
	var total = max(1, comps.size())
	var done = 0
	var changed = true
	var passes = 0
	while changed and passes < 8:
		passes += 1
		changed = false
		var i = 0
		while i < comps.size():
			var did = false
			var j = i + 1
			while j < comps.size():
				if comps[i].bb.grow(0.5).intersects(comps[j].bb) and _filled_overlap(comps[i], comps[j]):
					var m = _merge_components(comps[i], comps[j])
					comps.remove(j)
					if m.size() > 0:
						comps[i] = m[0]
						for k in range(1, m.size()):
							comps.append(m[k])
					else:
						comps.remove(i)
					changed = true
					did = true
					done += 1
					if progress != null and progress.pump():
						if p_to > p_from:
							progress.set_progress(p_from + (p_to - p_from) * min(1.0, float(done) / float(total)), "Merging barriers\u2026 (%d/%d)" % [done, total])
						yield(tree, "idle_frame")
						if progress.cancelled:
							return null
					break
				j += 1
			if not did:
				i += 1
	return comps


# Aplatit des composantes en pool typé pour _extract_click_region.
func _flatten_pool(comps: Array) -> Array:
	var pool = []
	for c in comps:
		pool.append({"ring": c.outer, "hole": false})
		for h in c.holes:
			pool.append({"ring": h, "hole": true})
	return pool


# Les aires PLEINES (outer − trous) de a et b se chevauchent-elles vraiment ?
func _filled_overlap(a: Dictionary, b: Dictionary) -> bool:
	var inter = Geometry.intersect_polygons_2d(a.outer, b.outer)
	if inter == null or inter.size() == 0:
		return false
	var pieces = []
	for p in inter:
		if p.size() >= 3 and not Geometry.is_polygon_clockwise(p):
			pieces.append(_to_array(p))
	pieces = _clip_pieces(pieces, a.holes)
	pieces = _clip_pieces(pieces, b.holes)
	for p in pieces:
		if _polygon_area(p) > 0.25:
			return true
	return false


# Soustrait successivement chaque polygone de `clips` de chaque morceau de
# `pieces` (broad-phase AABB). Les sorties CW (trou strictement inclus) sont
# ignorées : impossible dans nos cas d'usage (composantes connexes), et les
# ignorer ne fait que surestimer légèrement l'aire — sans danger.
func _clip_pieces(pieces: Array, clips: Array) -> Array:
	var cur = pieces
	for c in clips:
		if c.size() < 3: continue
		var cbb = _aabb(c).grow(0.5)
		var nxt = []
		for s in cur:
			if s.size() < 3: continue
			if not cbb.intersects(_aabb(s)):
				nxt.append(s)
				continue
			var res = Geometry.clip_polygons_2d(s, c)
			for r in res:
				if r.size() >= 3 and not Geometry.is_polygon_clockwise(r):
					nxt.append(_to_array(r))
		cur = nxt
	return cur


# Fusionne deux composantes dont les aires pleines se chevauchent.
# Aire pleine résultante = (Oa − Ha) ∪ (Ob − Hb). Trous du résultat :
#   • trous d'enceinte créés par Oa ∪ Ob (deux formes en C qui se referment),
#   • morceaux de chaque trou de a hors du disque de b (ha − Ob) — c'est ici
#     qu'un trou se SCINDE quand une cloison le traverse,
#   • symétriquement (hb − Oa),
#   • zones dans un trou de CHACUNE (ha ∩ hb).
# Ces familles sont disjointes par construction. Chaque trou est rattaché au
# plus petit outer qui contient son centroïde.
func _merge_components(a: Dictionary, b: Dictionary) -> Array:
	var m = Geometry.merge_polygons_2d(a.outer, b.outer)
	var outers = []
	var new_holes = []
	for p in m:
		if p.size() < 3: continue
		if Geometry.is_polygon_clockwise(p):
			new_holes.append(_ensure_ccw(_to_array(p)))
		else:
			outers.append(_to_array(p))
	if outers.size() == 0:
		return [a]
	for h in a.holes:
		for r in _clip_pieces([h], [b.outer]):
			new_holes.append(r)
	for h in b.holes:
		for r in _clip_pieces([h], [a.outer]):
			new_holes.append(r)
	for ha in a.holes:
		if ha.size() < 3: continue
		var ha_bb = _aabb(ha).grow(0.5)
		for hb in b.holes:
			if hb.size() < 3: continue
			if not ha_bb.intersects(_aabb(hb)): continue
			var inter = Geometry.intersect_polygons_2d(ha, hb)
			for r in inter:
				if r.size() >= 3 and not Geometry.is_polygon_clockwise(r):
					new_holes.append(_to_array(r))
	var comps = []
	for o in outers:
		comps.append({"outer": o, "holes": [], "bb": _aabb(o)})
	for h in new_holes:
		if _polygon_area(h) < 0.25: continue
		var cen = _ring_centroid(h)
		var best = -1
		var best_a = INF
		for ci in range(comps.size()):
			if not _point_in_polygon(cen, comps[ci].outer): continue
			var oa = _polygon_area(comps[ci].outer)
			if oa < best_a:
				best_a = oa
				best = ci
		if best >= 0:
			comps[best].holes.append(h)
	return comps


# Le pool est "typé" : [{ring, hole}] — l'appartenance trou/plein est explicite
# (plus de dépendance à l'orientation CW/CCW des anneaux de Clipper).
func _extract_click_region(pool: Array, map_rect: Array, mouse: Vector2) -> Dictionary:
	var smallest_idx = -1
	var smallest_area = INF
	for i in range(pool.size()):
		if pool[i].ring.size() < 3: continue
		if not _point_in_polygon(mouse, pool[i].ring): continue
		var a = _polygon_area(pool[i].ring)
		if a < smallest_area:
			smallest_area = a
			smallest_idx = i
	if smallest_idx < 0:
		# Extérieur : on soustrait RÉELLEMENT les composantes de premier niveau
		# du rectangle de map, puis on garde le morceau contenant le clic.
		# (Avant : map_rect + toutes les barrières en trous → une barrière
		# reliée aux bords de map ne séparait pas les zones, et une barrière
		# DÉBORDANT de la map donnait un trou sortant de l'outer → pontage
		# auto-croisé, « Bad Polygon ».)
		var pieces = [{"outer": map_rect, "holes": []}]
		for i in range(pool.size()):
			if pool[i].hole: continue
			if pool[i].ring.size() < 3: continue
			if _smallest_container_idx(i, pool) >= 0: continue
			pieces = _subtract_solid_from_pieces(pieces, pool[i].ring)
		for piece in pieces:
			if not _point_in_polygon(mouse, piece.outer): continue
			var in_hole = false
			for h in piece.holes:
				if _point_in_polygon(mouse, h):
					in_hole = true
					break
			if in_hole: continue
			return {"kind": "exterior", "outer": piece.outer, "holes": piece.holes}
		return {"kind": "wall", "outer": [], "holes": []}
	if not pool[smallest_idx].hole:
		return {"kind": "wall", "outer": [], "holes": []}
	var room = _ensure_ccw(pool[smallest_idx].ring)
	var islands = []
	for i in range(pool.size()):
		if i == smallest_idx: continue
		if pool[i].hole: continue
		if pool[i].ring.size() < 3: continue
		if _smallest_container_idx(i, pool) == smallest_idx:
			islands.append(pool[i].ring)
	return {"kind": "room", "outer": room, "holes": islands}


# Soustrait un solide (anneau plein) de chaque morceau {outer, holes} ; les
# anneaux CW produits (solide strictement inclus) deviennent des trous du
# morceau qui les contient. Broad-phase AABB.
func _subtract_solid_from_pieces(pieces: Array, solid: Array) -> Array:
	var sbb = _aabb(solid).grow(1.0)
	var result = []
	for piece in pieces:
		if not sbb.intersects(_aabb(piece.outer)):
			result.append(piece)
			continue
		var clipped = Geometry.clip_polygons_2d(piece.outer, solid)
		var newp = []
		var hs = []
		for r in clipped:
			if r.size() < 3: continue
			if Geometry.is_polygon_clockwise(r):
				hs.append(_ensure_ccw(_to_array(r)))
			else:
				newp.append({"outer": _to_array(r), "holes": []})
		for h in hs:
			_attach_hole_to_piece(newp, h)
		for h in piece.holes:
			_attach_hole_to_piece(newp, h)
		for p in newp:
			result.append(p)
	return result


func _attach_hole_to_piece(pieces: Array, h: Array):
	var cen = _ring_centroid(h)
	var best = -1
	var best_a = INF
	for i in range(pieces.size()):
		if not _point_in_polygon(cen, pieces[i].outer): continue
		var a = _polygon_area(pieces[i].outer)
		if a < best_a:
			best_a = a
			best = i
	if best >= 0:
		pieces[best].holes.append(h)


func _ring_centroid(ring: Array) -> Vector2:
	var c = Vector2(0, 0)
	for p in ring:
		c += p
	if ring.size() > 0:
		c /= ring.size()
	return c


func _smallest_container_idx(idx: int, pool: Array) -> int:
	# Containment robuste : on teste un point REPRÉSENTATIF (centroïde) de l'anneau
	# intérieur, pas tous ses points — un seul point effleurant le bord suffisait
	# sinon à rejeter le rattachement (l'oval ratait sa pièce).
	var area_i = _polygon_area(pool[idx].ring)
	var cen = _ring_centroid(pool[idx].ring)
	var best = -1
	var best_a = INF
	for j in range(pool.size()):
		if j == idx: continue
		if pool[j].ring.size() < 3: continue
		var aj = _polygon_area(pool[j].ring)
		if aj <= area_i: continue
		if not _point_in_polygon(cen, pool[j].ring): continue
		if aj < best_a:
			best_a = aj
			best = j
	return best


