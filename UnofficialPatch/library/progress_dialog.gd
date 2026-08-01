# library/progress_dialog.gd
# Boîte de progression non-bloquante + bouton Annuler pour les opérations longues
# (bucket fill pattern & terrain). N'apparaît QUE si l'opération dépasse un seuil,
# donc les remplissages instantanés ne provoquent aucun flash d'UI.
#
# Utilisation (dans une fonction coroutine) :
#   var pg = ResourceLoader.load(g.Root + "library/progress_dialog.gd", "GDScript", true).new()
#   pg._g = g
#   pg.start("Remplissage…")
#   for i in range(total):
#       ... travail lourd ...
#       if pg.pump():
#           pg.set_progress(float(i) / total, "%d / %d" % [i, total])
#           yield(g.Editor.get_tree(), "idle_frame")
#           if pg.cancelled:
#               break
#   pg.close()
#
# `pump()` gère toute la logique de seuil : tant que le seuil n'est pas franchi il
# renvoie false (aucune UI, aucun yield → chemin rapide). Une fois franchi il
# affiche la boîte puis renvoie true à intervalle régulier pour que l'appelant
# rafraîchisse la barre et rende la main (yield) → la boîte se dessine et le bouton
# Annuler devient cliquable.

var _g
var cancelled := false
# Liveness timestamp (ms): updated by start()/pump()/set_progress(). A healthy
# fill coroutine pumps on every loop iteration, so a long silence on this value
# while a fill is flagged as running means the coroutine died from a runtime
# error. The owning mod's watchdog reads this to recover.
var last_activity := 0

# Seuil (ms) avant affichage de la boîte. En-dessous : aucune UI.
var threshold_ms := 300
# Intervalle (ms) entre deux rafraîchissements une fois affichée (~30 fps).
var refresh_ms := 33

var _layer: CanvasLayer = null
var _win: WindowDialog = null
var _bar: ProgressBar = null
var _label: Label = null
var _title := "Filling…"
var _shown := false
var _closing := false
var _t_start := 0
var _t_last := 0
# Cible d'affichage (0..100), monotone croissante. La barre AFFICHÉE poursuit
# cette cible par lissage exponentiel à CHAQUE frame (signal idle_frame du
# SceneTree) : vitesse continue, pas d'à-coups quand les phases avancent à des
# rythmes différents ni de redémarrage d'animation à chaque mise à jour. À
# l'apparition (après le seuil), la barre part visuellement de 0 et rattrape.
var _target := 0.0
var _tree = null
var _t_frame := 0
# Estimation continue de la durée totale (s) : temps écoulé / fraction réelle,
# lissée. L'affichage avance à la vitesse moyenne estimée (quasi constante),
# PLAFONNÉ par la progression réelle : les segments rapides sont aplatis, les
# segments lents restent honnêtes (la barre ne dépasse jamais le travail fait).
var _t_total := -1.0


func start(title: String = "Filling…"):
	cancelled = false
	_shown = false
	_closing = false
	_title = title
	_target = 0.0
	_t_total = -1.0
	_t_start = OS.get_ticks_msec()
	_t_last = _t_start
	last_activity = _t_start


# À appeler à chaque itération de la boucle lourde. Renvoie true si l'appelant doit
# rafraîchir la barre puis yield cette frame (soit parce qu'on vient d'afficher la
# boîte, soit parce que l'intervalle de rafraîchissement est écoulé).
func pump() -> bool:
	last_activity = OS.get_ticks_msec()
	if cancelled:
		return false
	var now = last_activity
	if not _shown:
		if now - _t_start < threshold_ms:
			return false
		_build_and_popup()
		_shown = true
		_t_last = now
		return true
	if now - _t_last >= refresh_ms:
		_t_last = now
		return true
	return false


func set_progress(frac: float, status: String = ""):
	last_activity = OS.get_ticks_msec()
	_target = max(_target, clamp(frac, 0.0, 1.0) * 100.0)
	if _label != null and is_instance_valid(_label) and status != "":
		_label.text = status


# Appelé à chaque frame rendue tant que la boîte est visible. Poursuite
# exponentielle (rapide quand loin, douce à l'approche) + léger avancement
# linéaire pour ne jamais paraître figée entre deux mises à jour.
func _on_frame():
	if _bar == null or not is_instance_valid(_bar):
		return
	var now = OS.get_ticks_msec()
	var dt = clamp(float(now - _t_frame) / 1000.0, 0.0, 0.05)
	_t_frame = now
	var elapsed = float(now - _t_start) / 1000.0
	var frac = _target / 100.0
	if frac > 0.02 and not _closing:
		var t_est = elapsed / frac
		_t_total = t_est if _t_total <= 0.0 else lerp(_t_total, t_est, min(1.0, dt * 1.5))
	# Valeur "idéale" à vitesse moyenne constante, plafonnée par le réel.
	var desired = _target
	if _t_total > 0.0 and not _closing:
		desired = min(_target, 100.0 * elapsed / _t_total)
	if _bar.value < desired:
		var k = 8.0 if _closing else 4.0
		var lin = 60.0 if _closing else 1.0
		var v = _bar.value + (desired - _bar.value) * min(1.0, dt * k) + dt * lin
		_bar.value = min(desired, v)
	if _closing and _bar.value >= _target - 0.01:
		_finalize_close()


func close():
	_closing = true
	if _layer != null and is_instance_valid(_layer) and _shown and not cancelled and _g != null and _g.get("Editor") != null:
		# Laisse la poursuite atteindre 100 % avant de fermer (différé, non
		# bloquant ; _on_frame déclenche _finalize_close une fois la cible
		# atteinte, timer de sécurité sinon). IMPORTANT : l'appelant lâche sa
		# référence après close() et cet objet est une Reference — sans
		# keep-alive, l'objet meurt et le popup reste orphelin, figé sous
		# 100 %. La meta sur le layer nous garde en vie jusqu'au queue_free.
		_layer.set_meta("pg_keepalive", self)
		var t = _g.Editor.get_tree().create_timer(1.2)
		t.connect("timeout", self, "_finalize_close")
		return
	_finalize_close()


# Watchdog escape hatch: tear the window down immediately (no closing
# animation). Used when the owning fill coroutine died mid-operation and the
# modal dialog would otherwise stay open forever, freezing the whole UI.
func force_close():
	cancelled = true
	_closing = true
	_finalize_close()


func _finalize_close():
	if _tree != null and _tree.is_connected("idle_frame", self, "_on_frame"):
		_tree.disconnect("idle_frame", self, "_on_frame")
	_tree = null
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_win = null
	_bar = null
	_label = null
	_shown = false


func _build_and_popup():
	var root = null
	if _g != null and _g.get("Editor") != null:
		root = _g.Editor.get_tree().get_root()
	if root == null:
		return
	# CanvasLayer dédié (layer élevé) pour passer au-dessus de l'UI DD.
	_layer = CanvasLayer.new()
	_layer.layer = 128
	root.add_child(_layer)

	_win = WindowDialog.new()
	_win.window_title = _title
	_win.resizable = false
	_win.rect_min_size = Vector2(340, 130)
	_layer.add_child(_win)

	var mc = MarginContainer.new()
	mc.set_anchors_preset(Control.PRESET_WIDE)
	mc.add_constant_override("margin_left", 14)
	mc.add_constant_override("margin_right", 14)
	mc.add_constant_override("margin_top", 14)
	mc.add_constant_override("margin_bottom", 14)
	_win.add_child(mc)

	var vb = VBoxContainer.new()
	vb.add_constant_override("separation", 10)
	mc.add_child(vb)

	_label = Label.new()
	_label.text = _title
	vb.add_child(_label)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.value = 0.0
	_bar.rect_min_size = Vector2(0, 20)
	vb.add_child(_bar)

	var btn = Button.new()
	btn.text = "Cancel"
	btn.rect_min_size = Vector2(0, 28)
	btn.focus_mode = Control.FOCUS_NONE
	btn.connect("pressed", self, "_on_cancel")
	vb.add_child(btn)

	_win.connect("popup_hide", self, "_on_popup_hide")
	_win.popup_centered(Vector2(340, 130))
	_register_blur()
	# Poursuite animée à chaque frame ; la barre part de 0 et rattrape la
	# progression déjà accomplie pendant le seuil.
	_tree = _g.Editor.get_tree()
	_t_frame = OS.get_ticks_msec()
	if not _tree.is_connected("idle_frame", self, "_on_frame"):
		_tree.connect("idle_frame", self, "_on_frame")


# Blur d'arrière-plan via le mod popup_blur (singleton exposé dans Engine). Le
# WindowDialog vit sous un CanvasLayer à nous, donc on passe par l'API publique
# register() prévue pour les popups hors hiérarchie DD.
func _register_blur():
	if not Engine.has_meta("popup_blur_singleton"):
		return
	var pb = Engine.get_meta("popup_blur_singleton")
	if pb != null and pb.has_method("register"):
		pb.register(_win)


func _on_cancel():
	cancelled = true


func _on_popup_hide():
	# Clic hors de la boîte / croix de fermeture = annulation (sauf si c'est nous
	# qui fermons volontairement via close()).
	if not _closing:
		cancelled = true
