const RG_VERSION = "RG-4"  # + optional layer filter (min_layer) and keep_holes output
# region_geometry.gd  (library/)
#
# Moteur de géométrie partagé : calcule la région fermée (bornée par murs, paths
# et bords de map) contenant un point donné. Extrait du pattern_paint_bucket pour
# être réutilisé par le terrain bucket.
#
# Utilisation :
#   var geo = ResourceLoader.load(g.Root + "library/region_geometry.gd", "GDScript", true).new()
#   geo._g = g
#   var region = geo.compute_region(mouse_world, stop_walls, stop_paths, stop_patterns)
#   # region.outer : polygone simple (trous encodés via bridge-cuts, testables en
#   #                even-odd avec point_in_polygon). [] si clic hors région / sur un mur.
#
# La région renvoyée est un polygone "ponté" : les trous internes sont reliés à
# l'extérieur par des fentes de largeur nulle, donc un test point-in-polygon
# even-odd exclut correctement les trous. Pratique pour rasteriser (terrain) ou
# créer une PatternShape (pattern).

var _g

# px de chaque côté de la polyline. Doit être suffisant pour que deux barrières
# perpendiculaires se chevauchent de façon robuste au croisement.
const BARRIER_THICKNESS = 2.0
const EDGE_SNAP_THRESHOLD = 16.0   # endpoint à <N px d'un bord → snappé sur le bord
const EDGE_OVERSHOOT = 2.0         # quand on snappe, on dépasse de N px pour bien couper
# Au-delà de N sommets, on saute le test d'auto-intersection O(n²) et on offsette
# directement en bande unique (un path aussi dense est une courbe lisse, pas un
# tracé qui se croise).
const SELF_INTERSECT_CHECK_MAX = 512


# ── API publique ─────────────────────────────────────────────────────────────

func compute_region(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool) -> Dictionary:
	# Délègue à la variante coroutine. Avec progress=null, aucun yield n'est exécuté,
	# donc la fonction renvoie directement un Dictionary (pas de GDScriptFunctionState).
	return compute_region_async(mouse_world, stop_walls, stop_paths, stop_patterns, null)


# Variante coroutine à FENÊTRE EXTENSIBLE amorcée au clic. Au lieu de découper
# toute la map (coût ∝ complexité globale), on part d'une petite boîte autour du
# clic, on ne garde que les barrières dont l'AABB la touche, on calcule la région,
# et si celle-ci s'appuie sur un bord INTÉRIEUR de la boîte (pas encore scellée) on
# double la boîte et on recommence — jusqu'à convergence (ou toute la map).
#
# Exact : toute barrière qui borde la région finale touche la région ⊂ boîte, donc
# son AABB touche la boîte → elle est incluse dans l'itération convergente. Le coût
# devient ∝ complexité LOCALE de la pièce cliquée.
#
# Renvoie {outer, holes, cancelled}. `progress` peut être null (pas d'UI/yield).
# [p_from, p_to] : plage de progression allouée par l'appelant à cette phase
# (permet une échelle UNIQUE quand l'appelant enchaîne d'autres phases).
func compute_region_async(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool, progress, p_from := 0.0, p_to := 0.9, min_layer = null, keep_holes := false) -> Dictionary:
	# min_layer : si non-null, les barrières strictement SOUS ce calque sont
	# ignorées (usage pattern bucket : ce qui est sous le calque-cible sera
	# recouvert par le pattern, donc ne doit pas le borner).
	# keep_holes : si vrai, renvoie outer + holes séparés (sans bridge-cuts) —
	# l'appelant fait son propre pontage (pattern bucket).
	var map_rect = _get_map_bounds_polygon()
	if map_rect.size() < 3:
		return {"outer": [], "holes": [], "cancelled": false}
	var tree = _g.Editor.get_tree()
	# ~25 % de la plage pour la lecture/offset des barrières, le reste pour
	# la fenêtre + l'union — la barre progresse dès le début.
	var p_build_to = p_from + (p_to - p_from) * 0.25
	var solids = _build_barrier_solids(stop_walls, stop_paths, stop_patterns, progress, tree, p_from, p_build_to, min_layer)
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
			progress.set_progress(p_build_to + (p_to - p_build_to) * frac_before, "Computing fill region\u2026")
			yield(tree, "idle_frame")
			if progress.cancelled:
				return {"outer": [], "holes": [], "cancelled": true}
		if added > 0:
			var merged = _union_components(comps, progress, tree, p_build_to + (p_to - p_build_to) * frac_before, p_build_to + (p_to - p_build_to) * frac_now)
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
		# Jalon rendu avant le pontage/assemblage final (sinon saut jusqu'à
		# la valeur suivante posée par l'appelant).
		progress.set_progress(p_to, "Extracting region\u2026")
		yield(tree, "idle_frame")
		if progress.cancelled:
			return {"outer": [], "holes": [], "cancelled": true}
	if out_outer.size() < 3:
		return {"outer": [], "holes": [], "cancelled": false}
	if keep_holes:
		return {"outer": out_outer, "holes": out_holes, "cancelled": false}
	var final_poly = out_outer
	if out_holes.size() > 0:
		final_poly = _eliminate_holes(out_outer, out_holes)
	return {"outer": final_poly, "holes": [], "cancelled": false}


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


# La fenêtre couvre-t-elle (à eps près) toute la map ? Si oui, plus rien à étendre.
func _rect_covers(box: Rect2, map_bb: Rect2, eps: float) -> bool:
	return box.position.x <= map_bb.position.x + eps and box.position.y <= map_bb.position.y + eps \
		and box.end.x >= map_bb.end.x - eps and box.end.y >= map_bb.end.y - eps


# La région touche-t-elle un bord de la fenêtre qui n'est PAS un vrai bord de map ?
# (auquel cas elle n'est pas scellée de ce côté → il faut étendre la fenêtre.)
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


# Test even-odd : le point est-il dans l'aire remplie du polygone ponté ?
func point_in_region(point: Vector2, region_outer: Array) -> bool:
	return _point_in_polygon(point, region_outer)


func get_map_bounds_polygon() -> Array:
	return _get_map_bounds_polygon()


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


func _get_path_polyline(path_node) -> Array:
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


# ── Géométrie de base ────────────────────────────────────────────────────────

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
	if dmin == dl: return Vector2(-EDGE_OVERSHOOT, p.y)
	if dmin == dr: return Vector2(w + EDGE_OVERSHOOT, p.y)
	if dmin == dt: return Vector2(p.x, -EDGE_OVERSHOOT)
	if dmin == db: return Vector2(p.x, h + EDGE_OVERSHOOT)
	return p


# ── Construction des barriers ────────────────────────────────────────────────

func _build_barriers(stop_walls: bool, stop_paths: bool, stop_patterns: bool) -> Dictionary:
	var result = {"closed_pairs": [], "subs_last": []}
	var level = _get_current_level()
	if level == null: return result

	var walls_node = level.get("Walls") if stop_walls else null
	if walls_node != null:
		for child in walls_node.get_children():
			if not is_instance_valid(child): continue
			var pts_raw = child.get("Points")
			if pts_raw == null or pts_raw.size() < 2: continue
			# Les Points d'un Wall sont en espace LOCAL au nœud : on applique son
			# transform global (no-op si identité). Sans ça, un mur déplacé/tourné
			# via l'outil Select donne une région décalée.
			var xform = child.get_global_transform()
			var pts = []
			for p in pts_raw:
				pts.append(xform.xform(p))
			var loop = bool(child.get("Loop"))
			_classify_polyline_barrier(pts, loop, result)

	var paths_node = level.get("Pathways") if stop_paths else null
	if paths_node != null:
		for child in paths_node.get_children():
			if not is_instance_valid(child): continue
			var pts = _get_path_polyline(child)
			if pts.size() < 2: continue
			var loop = bool(child.get("Loop"))
			_classify_polyline_barrier(pts, loop, result)

	if stop_patterns:
		for shape in _get_all_pattern_shapes():
			var pts = _get_pattern_polygon(shape)
			if pts.size() >= 3:
				result.subs_last.append(pts)

	return result


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


func _polyline_self_intersects(pts: Array, closed: bool) -> bool:
	var n = pts.size()
	if n < 4: return false
	var seg_count = n if closed else n - 1
	for i in range(seg_count):
		var a1 = pts[i]
		var a2 = pts[(i + 1) % n]
		for j in range(i + 1, seg_count):
			if j == i + 1:
				continue
			if closed and i == 0 and j == seg_count - 1:
				continue
			var b1 = pts[j]
			var b2 = pts[(j + 1) % n]
			if Geometry.segment_intersects_segment_2d(a1, a2, b1, b2) != null:
				return true
	return false


func _classify_polyline_barrier(pts: Array, loop: bool, out: Dictionary):
	if pts.size() < 2: return

	if pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) < 2.0:
		pts.pop_back()
		loop = true
	if pts.size() < 2: return

	if not loop:
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

	if _polyline_self_intersects(pts, true):
		_append_segment_quads(pts, true, out)
		return

	var offset_result = Geometry.offset_polyline_2d(pts, BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_JOINED)
	var polys = []
	for b in offset_result:
		if b.size() >= 3:
			polys.append(_to_array(b))
	if polys.size() == 0:
		return
	if polys.size() == 1:
		out.closed_pairs.append({"outer": polys[0], "inner": null})
		return
	var i_big := 0
	var i_small := 1
	if _polygon_area(polys[1]) > _polygon_area(polys[0]):
		i_big = 1; i_small = 0
	out.closed_pairs.append({"outer": polys[i_big], "inner": polys[i_small]})
	for i in range(polys.size()):
		if i == i_big or i == i_small: continue
		out.closed_pairs.append({"outer": polys[i], "inner": null})


# ── Pipeline de soustraction + recombinaison ─────────────────────────────────

func _sort_closed_pairs_by_outer_area_desc(a, b) -> bool:
	return _polygon_area(a.outer) > _polygon_area(b.outer)


# Soustrait `barrier` de chaque région, recombine, et maintient un cache d'AABB
# parallèle. Rejet broad-phase : une région dont l'AABB ne croise pas celle du
# barrier ne peut pas être découpée → on la conserve telle quelle sans appeler
# Clipper (le clip d'un polygone disjoint renverrait le sujet inchangé).
func _subtract_and_combine(regions: Array, region_bbs: Array, barrier: Array) -> Dictionary:
	var new_regions = []
	var new_bbs = []
	var bb = _aabb(barrier).grow(1.0)
	for ri in range(regions.size()):
		var r = regions[ri]
		var r_bb = region_bbs[ri]
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


func _combine_outer_holes(polygons_pool: Array) -> Array:
	var polys = []
	for p in polygons_pool:
		if p.size() >= 3:
			polys.append(_to_array(p))
	if polys.size() <= 1:
		return polys

	var parents = []
	for i in range(polys.size()):
		parents.append(_find_immediate_parent_idx(i, polys))

	var depths = []
	for i in range(polys.size()):
		var d = 0
		var p_idx = parents[i]
		while p_idx >= 0:
			d += 1
			p_idx = parents[p_idx]
		depths.append(d)

	var result = []
	for i in range(polys.size()):
		if depths[i] % 2 != 0: continue
		var outer = polys[i]
		var outer_holes = []
		for j in range(polys.size()):
			if depths[j] % 2 == 0: continue
			if parents[j] == i:
				outer_holes.append(polys[j])
		if outer_holes.size() == 0:
			result.append(outer)
		else:
			result.append(_eliminate_holes(outer, outer_holes))
	return result


func _find_immediate_parent_idx(p_idx: int, polygons: Array) -> int:
	var p_area = _polygon_area(polygons[p_idx])
	var min_parent_area = INF
	var min_parent_idx = -1
	for q_idx in range(polygons.size()):
		if q_idx == p_idx: continue
		var q_area = _polygon_area(polygons[q_idx])
		if q_area <= p_area: continue
		if not _polygon_inside_polygon(polygons[p_idx], polygons[q_idx]): continue
		if q_area < min_parent_area:
			min_parent_area = q_area
			min_parent_idx = q_idx
	return min_parent_idx


# ── Élimination de trous robuste (earcut) ────────────────────────────────────

func _eliminate_holes(outer_in: Array, holes_in: Array) -> Array:
	if holes_in.size() == 0:
		return outer_in
	var outer = _flip_y(outer_in)
	if _ring_signed_area(outer) < 0.0:
		outer.invert()
	var prepared = []
	for h in holes_in:
		var hp = _flip_y(h)
		if _ring_signed_area(hp) > 0.0:
			hp.invert()
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
		var bd = INF
		bi = 0
		for i in range(outer.size()):
			var d = outer[i].distance_squared_to(hole[hi])
			if d < bd:
				bd = d; bi = i
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


func _find_hole_bridge(outer: Array, hole: Array, hi: int) -> int:
	var hx = hole[hi].x
	var hy = hole[hi].y
	var qx = -INF
	var m = -1
	var n = outer.size()
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


# Liste plate des SOLIDES de toutes les barrières activées (murs/paths → bandes ou
# quads par segment ; patterns → polygone). Tous normalisés CCW.
# Si `progress` est fourni : publie la lecture des barrières sur [p_from, p_to]
# et pompe l'UI (yield) — c'était la phase silencieuse responsable du saut
# initial de la barre. Renvoie null si annulé ; synchrone sans progress.
func _build_barrier_solids(stop_walls: bool, stop_paths: bool, stop_patterns: bool, progress = null, tree = null, p_from := 0.0, p_to := 0.0, min_layer = null):
	var solids = []
	var level = _get_current_level()
	if level == null: return solids

	var items = []
	var walls_node = level.get("Walls") if stop_walls else null
	if walls_node != null:
		for child in walls_node.get_children():
			if is_instance_valid(child) and not _is_below_layer(child, min_layer):
				items.append(["wall", child])
	# Portails freestanding (WallID == -1) : traités comme des barrières "mur"
	# (mêmes cases à cocher). Les portails attachés à un mur sont ignorés — la
	# polyline du mur passe déjà dessus, ils ne créent pas d'ouverture.
	var portals_node = level.get("Portals") if stop_walls else null
	if portals_node != null:
		for child in portals_node.get_children():
			if is_instance_valid(child) and child.get("WallID") != null and int(child.get("WallID")) == -1 and not _is_below_layer(child, min_layer):
				items.append(["portal", child])
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
		elif kind == "portal":
			var seg = _get_freestanding_portal_segment(node)
			if seg.size() == 2:
				_append_barrier_solids(seg, false, solids)
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




# Le nœud est-il strictement SOUS le calque min_layer ? Faux si min_layer est
# null ou si le calque du nœud est indéterminable (on garde alors la barrière
# par sécurité). Lecture du calque alignée sur path_fix : GetLayer() si dispo
# (PatternShape), sinon _effective_z() (murs/paths — un Pathway n'expose PAS
# GetLayer, son calque EST son z_index ; il faut sommer les z_index le long de
# la chaîne parente).
func _is_below_layer(node, min_layer) -> bool:
	if min_layer == null: return false
	if not (node is CanvasItem): return false
	var l = node.GetLayer() if node.has_method("GetLayer") else _effective_z(node)
	return int(l) < min_layer


# z effectif d'un CanvasItem : somme des z_index le long de la chaîne parente
# tant que z_as_relative est vrai (modèle DD : sous-conteneurs z_as_relative=true
# qui héritent du z de la couche). Comparable à PatternShapeTool.ActiveLayer.
func _effective_z(ci) -> int:
	var z = 0
	var n = ci
	while n != null and n is CanvasItem:
		z += n.z_index
		if not n.z_as_relative:
			break
		n = n.get_parent()
	return z

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
		for ring in _split_ring_pinches_fast(_to_array(poly)):
			if ring.size() < 3 or _polygon_area(ring) < 0.25:
				continue
			if Geometry.is_polygon_clockwise(PoolVector2Array(ring)):
				holes.append(_ensure_ccw(ring))
			else:
				outers.append(ring)
	var comps = []
	for o in outers:
		comps.append({"outer": o, "holes": []})
	for h in holes:
		_attach_hole_robust(h, comps)
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


# Segment barrière d'un portail freestanding (porte posée hors mur) : le
# portail expose GlobalPosition, Direction (unitaire, espace global — même
# convention que Portal.Begin/End côté C#) et Radius (demi-largeur). Renvoie
# [] si le nœud n'est pas exploitable.
func _get_freestanding_portal_segment(portal) -> Array:
	var radius = portal.get("Radius")
	if radius == null: return []
	var r = float(radius)
	if r <= 0.5: return []
	var dir = portal.get("Direction")
	if dir is Vector2 and dir.length() > 0.001:
		dir = dir.normalized()
	else:
		dir = Vector2.RIGHT.rotated(portal.global_rotation)
	var pos = portal.global_position
	return [pos - dir * r, pos + dir * r]


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
		for ring in _split_ring_pinches_fast(_to_array(p)):
			if ring.size() < 3 or _polygon_area(ring) < 0.25:
				continue
			if Geometry.is_polygon_clockwise(PoolVector2Array(ring)):
				new_holes.append(_ensure_ccw(ring))
			else:
				outers.append(ring)
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
		_attach_hole_robust(h, comps)
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




# Attache un trou au comp le plus petit qui le contient. Le test par rayon
# seul est instable quand la géométrie regorge d'arêtes quasi horizontales
# (soleil à ~0°/180°) : un raté de parité JETAIT le trou en silence — une
# poche éclairée se remplissait d'ombre. Échelle : test custom → test natif
# Godot → rattachement au comp le plus proche (jamais d'abandon muet).
func _attach_hole_robust(h: Array, comps: Array):
	if comps.size() == 0 or h.size() < 3:
		return
	var cen = _ring_centroid(h)
	for probe in range(2):
		var best = -1
		var best_a = INF
		for ci in range(comps.size()):
			var inside = _point_in_polygon(cen, comps[ci].outer) if probe == 0 \
					else Geometry.is_point_in_polygon(cen, PoolVector2Array(comps[ci].outer))
			if not inside:
				continue
			var oa = _polygon_area(comps[ci].outer)
			if oa < best_a:
				best_a = oa
				best = ci
		if best >= 0:
			comps[best].holes.append(h)
			return
	var near = -1
	var near_d = INF
	for ci in range(comps.size()):
		for p in comps[ci].outer:
			var d = cen.distance_squared_to(p)
			if d < near_d:
				near_d = d
				near = ci
	if near >= 0:
		comps[near].holes.append(h)


# Scinde un anneau à chaque paire de sommets coïncidents (scan par hachage,
# O(n)). Aux angles de soleil quasi horizontaux, Clipper peut fusionner un
# outer et son trou tangent en UN SEUL anneau auto-tangent (« en huit ») :
# classé CCW tel quel, la poche intérieure devient du plein. Scinder aux
# pincements rend au lobe intérieur son enroulement CW → trou.
func _split_ring_pinches_fast(pts: Array) -> Array:
	var n = pts.size()
	if n < 4:
		return [pts]
	var seen = {}
	for idx in range(n):
		var key = "%.1f_%.1f" % [pts[idx].x, pts[idx].y]
		if seen.has(key):
			var i = seen[key]
			if idx > i + 1 and not (i == 0 and idx == n - 1) and pts[i].distance_to(pts[idx]) <= 0.03:
				var r1 = []
				for k in range(i, idx):
					r1.append(pts[k])
				var r2 = []
				for k in range(idx, n):
					r2.append(pts[k])
				for k in range(0, i):
					r2.append(pts[k])
				return _split_ring_pinches_fast(r1) + _split_ring_pinches_fast(r2)
		seen[key] = idx
	return [pts]
