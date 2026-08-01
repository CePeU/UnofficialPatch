# export_light_fix.gd
# Fix vanilla : lors d'un export multi-level (source + overlay), DD bascule
# le level overlay sur le light mask 4 via Level.SetAllLightMasks(). Cette
# methode propage le mask aux lights, au LightPassRender et aux occluders
# des walls (portals de wall inclus, via Wall.SetOccluderLightMask) — mais
# OUBLIE les freestanding portals (node Level.Portals). Leurs LightOccluder
# restent a light_mask=2, donc les lights de l'overlay (shadow cull mask 4)
# les traversent. En export "level simple", tout reste a 2, d'ou l'absence
# du bug dans ce mode.
# Solution : sync par polling — le light_mask de l'occluder de chaque
# freestanding portal est aligne sur celui du LightPassRender de son level
# (source de verite posee par SetAllLightMasks). Couvre automatiquement la
# restauration post-export (RestoreLevelsPostExport remet tout a 2) ainsi
# que les portals crees/charges pendant qu'un mask non-standard est actif.

var _g

const SYNC_INTERVAL = 0.1

var _timer = null
var _timer_world_id := 0


func initialize() -> void:
	pass


# Le update() des mods est gele par DD pendant qu'une fenetre modale (dont
# ExportWindow) est ouverte — precisement la periode ou les masks overlay
# sont actifs. On pilote donc le sync par un Timer attache au World : le
# SceneTree continue de tourner pendant les modals, le timer fire toujours.
func update(_delta) -> void:
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return
	var wid = _g.World.get_instance_id()
	if _timer == null or not is_instance_valid(_timer) or _timer_world_id != wid:
		_timer = Timer.new()
		_timer.wait_time = SYNC_INTERVAL
		_timer.autostart = true
		_timer.connect("timeout", self, "_sync")
		_g.World.call_deferred("add_child", _timer)
		_timer_world_id = wid


func _sync() -> void:
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return
	var levels = _g.World.get_AllLevels()
	if levels == null:
		return
	for level in levels:
		if level == null or not is_instance_valid(level):
			continue
		# LightPassRender recoit le mask dans Level.SetAllLightMasks : c'est
		# la reference fiable du mask courant du level (2 normal, 4 overlay).
		var lpr = level.get("LightPassRender")
		if lpr == null or not is_instance_valid(lpr):
			continue
		var mask = lpr.light_mask
		var portals = level.get("Portals")
		if portals == null or not is_instance_valid(portals):
			continue
		for portal in portals.get_children():
			# LightOccluder peut etre null si le portal n'est pas encore
			# entre dans l'arbre (_EnterTree pas encore execute).
			var occ = portal.get("LightOccluder")
			if occ != null and is_instance_valid(occ) and occ.light_mask != mask:
				occ.light_mask = mask

