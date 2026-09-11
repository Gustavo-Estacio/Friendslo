extends StaticBody3D

@export var health := 100

func take_damage(damage: int):
	var next_health = health - damage
	
	if next_health <= 0:
		queue_free()
	else:
		health = next_health
