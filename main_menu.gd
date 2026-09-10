extends CanvasLayer

@onready var button_join: Button = $Control/PanelContainer/MarginContainer/VBoxContainer/ButtonJoin
@onready var button_quit: Button = $Control/PanelContainer/MarginContainer/VBoxContainer/ButtonQuit

const WORLD = preload("uid://cqn60bapogc82")
const PLAYER = preload("uid://ctiit2ns222ig")


func _ready() -> void:
	button_join.pressed.connect(on_join)
	button_quit.pressed.connect(func(): get_tree().quit())
	
	if OS.has_feature('server'):
		Network.start_server()
		add_world()
		hide()

func on_join():
	Network.join_server()
	add_world()
	hide()

func add_world():
	var new_world = WORLD.instantiate()
	get_tree().current_scene.add_child(new_world)
	hide()
