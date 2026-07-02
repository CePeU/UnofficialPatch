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


func start(title: String = "Filling…"):
	cancelled = false
	_shown = false
	_closing = false
	_title = title
	_t_start = OS.get_ticks_msec()
	_t_last = _t_start


# À appeler à chaque itération de la boucle lourde. Renvoie true si l'appelant doit
# rafraîchir la barre puis yield cette frame (soit parce qu'on vient d'afficher la
# boîte, soit parce que l'intervalle de rafraîchissement est écoulé).
func pump() -> bool:
	if cancelled:
		return false
	var now = OS.get_ticks_msec()
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
	if _bar != null and is_instance_valid(_bar):
		_bar.value = clamp(frac, 0.0, 1.0) * 100.0
	if _label != null and is_instance_valid(_label) and status != "":
		_label.text = status


func close():
	_closing = true
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
