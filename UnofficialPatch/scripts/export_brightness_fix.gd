# export_brightness_fix.gd
# Fixes light sources appearing to change blend mode in the Export window
# when Brightness or Focus drops below 100%.
#
# Vanilla pipeline: ExportFX (Polygon2D + BlurScreen.shader) redraws the
# screen captured by LightPassBBC, i.e. BEFORE the ambient tint and the
# light passes. DD re-applies the ambient via ExportFX.Modulate, but in
# Godot 3 the modulate multiplies the WHOLE output, light passes included:
# the additive light highlights get crushed by the ambient color.
#
# Fix: swap ExportFX's material for an equivalent shader that applies the
# ambient tint on the base pass only (AT_LIGHT_PASS branch, same trick as
# DeferredLighting.shader), and keep the modulate white. ExportWindow
# re-reads ExportFX.Material on every slider change, so its writes to
# "color"/"blur" land in our material transparently.
#
# NB : Main.update() ne tourne pas pendant la fenetre d'export modale,
# d'ou le Timer ajoute a l'arbre (pattern de wall_tool_portal_fix.gd).

var _g
var _shader = null

const CHECK_INTERVAL = 0.05

const SHADER_CODE = """
shader_type canvas_item;

uniform vec4 color : hint_color = vec4(0.0);
uniform float blur = 0.0;
uniform vec4 ambient : hint_color = vec4(1.0);

void fragment() {
	vec3 base = mix(textureLod(SCREEN_TEXTURE, SCREEN_UV, blur).rgb, color.rgb, color.a);
	if (AT_LIGHT_PASS) {
		// Passe de lumiere : ne pas teinter, la lumiere revele la base brute
		// (meme logique que DeferredLighting.shader)
		COLOR.rgb = base;
	} else {
		// Passe de base : appliquer la teinte ambiante une seule fois
		COLOR.rgb = mix(base, base * ambient.rgb, ambient.a);
	}
}
"""


func initialize():
	_shader = Shader.new()
	_shader.code = SHADER_CODE
	# Cross-session guard: _g.Editor persists across map reloads, so an autostart
	# Timer added by a previous mod instance keeps ticking forever. Free the
	# previous one before adding ours -- otherwise they accumulate per reload.
	if Engine.has_meta("ebf_timer"):
		var _old_t = Engine.get_meta("ebf_timer")
		if is_instance_valid(_old_t):
			_old_t.queue_free()
	var timer = Timer.new()
	timer.wait_time = CHECK_INTERVAL
	timer.autostart = true
	timer.connect("timeout", self, "_tick")
	Engine.set_meta("ebf_timer", timer)
	_g.Editor.add_child(timer)
	print("[ExportBrightnessFix] initialized")


func update(_delta):
	pass


func _tick():
	var world = _g.World
	if world == null:
		return
	var fx = world.get("ExportFX")
	if fx == null or not is_instance_valid(fx):
		return
	_ensure_shader(fx)
	if not fx.visible:
		return
	# Neutraliser le modulate vanilla (applique APRES le shader, donc sur
	# les passes de lumiere aussi) : la teinte passe par l'uniform ambient
	if fx.modulate != Color(1, 1, 1, 1):
		fx.modulate = Color(1, 1, 1, 1)
	var source_level = world.get("SourceLevel")
	if source_level == null or not is_instance_valid(source_level):
		return
	var lpr = source_level.get("LightPassRender")
	if lpr == null or not is_instance_valid(lpr):
		return
	var mat = fx.material
	if mat != null and mat is ShaderMaterial:
		mat.set_shader_param("ambient", lpr.color)


func _ensure_shader(fx):
	var mat = fx.material
	if mat != null and mat is ShaderMaterial and mat.shader == _shader:
		return
	var new_mat = ShaderMaterial.new()
	new_mat.shader = _shader
	# Reprendre les valeurs courantes des sliders (DD ecrira ensuite
	# directement dans ce materiau via ExportFX.Material)
	if mat != null and mat is ShaderMaterial:
		var c = mat.get_shader_param("color")
		if c != null:
			new_mat.set_shader_param("color", c)
		var b = mat.get_shader_param("blur")
		if b != null:
			new_mat.set_shader_param("blur", b)
	fx.material = new_mat
	print("[ExportBrightnessFix] Custom ExportFX shader installed")
