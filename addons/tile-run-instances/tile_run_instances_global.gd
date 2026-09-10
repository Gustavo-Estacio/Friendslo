extends Node

@export var target_monitor: int = -1
@export var window_margin_gap: int = 4
@export var debug_logging: bool = true

# Arquivo compartilhado entre as instâncias (cada uma tem o mesmo user://)
const SESSION_FILE = "user://tile_sessions.json"
const SESSION_TTL_SEC = 30.0   # PIDs antigos são descartados após 30s
const SETTLE_DELAY_SEC = 0.6   # Tempo para todas as instâncias se registrarem


func _ready() -> void:
	if debug_logging:
		print("[tile-run-instances] _ready PID=", OS.get_process_id())

	# Mantém o canal antigo por compatibilidade (se você já tiver o addon)
	EngineDebugger.register_message_capture("tile-run-instances", _on_tile_instances)
	_request_id_when_ready()

	# Mecanismo autônomo: registra no arquivo e posiciona após SETTLE_DELAY_SEC
	_register_and_tile_via_file()


# === Mecanismo por arquivo (não depende do editor) ===

func _register_and_tile_via_file() -> void:
	var my_pid := OS.get_process_id()
	var now := Time.get_unix_time_from_system()

	var sessions := _read_sessions()

	# Limpa entradas expiradas
	var cleaned := {}
	for pid in sessions:
		var ts = sessions[pid]
		if typeof(ts) == TYPE_FLOAT and (now - ts) < SESSION_TTL_SEC:
			cleaned[pid] = ts

	# Registra a si mesma
	cleaned[my_pid] = now
	_write_sessions(cleaned)

	if debug_logging:
		print("[tile-run-instances] registrado PID=", my_pid, " sessões=", cleaned)

	# Espera as irmãs chegarem
	await get_tree().create_timer(SETTLE_DELAY_SEC).timeout

	_tile_from_file()


func _tile_from_file() -> void:
	var my_pid := OS.get_process_id()
	var sessions := _read_sessions()
	var pids: Array = sessions.keys()
	pids.sort()

	var my_index := pids.find(my_pid)
	var total := pids.size()

	if debug_logging:
		print("[tile-run-instances] tiling via arquivo: index=", my_index, " total=", total, " pids=", pids)

	if total <= 1 or my_index < 0:
		return

	_tile_window(my_index, total)


# Re-verifica periodicamente para o caso de instâncias fecharem/abrirem
func _schedule_refresh() -> void:
	while is_instance_valid(self):
		await get_tree().create_timer(2.0).timeout
		_tile_from_file()


# === Caminho legado via editor (mantido, mas opcional) ===

func _request_id_when_ready(attempts_left: int = 300) -> void:
	if not EngineDebugger.is_active():
		if attempts_left <= 0:
			return
		await get_tree().process_frame
		_request_id_when_ready(attempts_left - 1)
		return
	EngineDebugger.send_message("tile-run-instances:get_id", [])


func _on_tile_instances(message: String, data: Array) -> bool:
	if message != "session_id":
		return false

	var info: Dictionary = data[0]
	var my_session_id: int = info.get("id", -1)
	var active_sessions: Array = info.get("all", [])

	if active_sessions.size() <= 1:
		return true

	for instance_index in active_sessions.size():
		if active_sessions[instance_index] == my_session_id:
			_tile_window(instance_index, active_sessions.size())
			break
	return true


# === Lógica de tiling ===

func _tile_window(instance_index: int, total_instances: int) -> void:
	var window := get_window()
	var screen := _get_target_screen()
	var screen_rect := DisplayServer.screen_get_usable_rect(screen)

	window.current_screen = screen

	var grid := _calculate_grid_layout(total_instances)
	var cell_size := _get_cell_size(grid, screen_rect)
	var position := _get_grid_position(instance_index, grid, screen_rect, cell_size)

	if debug_logging:
		print("[tile-run-instances] _tile_window idx=", instance_index, " grid=", grid,
			" size=", cell_size, " pos=", position)

	window.size = cell_size
	window.position = position


func _get_target_screen() -> int:
	var screen_count := DisplayServer.get_screen_count()
	if target_monitor < 0:
		return get_window().current_screen
	elif target_monitor < screen_count:
		return target_monitor
	else:
		push_warning("tile-run-instances: Monitor %d não encontrado (%d disponíveis), usando primário" % [target_monitor, screen_count])
		return DisplayServer.get_primary_screen()


func _calculate_grid_layout(total: int) -> Vector2i:
	if total <= 1:
		return Vector2i(1, 1)
	elif total == 2:
		return Vector2i(2, 1)
	elif total == 3:
		return Vector2i(2, 2)   # 3 dos 4 quadrantes
	elif total <= 4:
		return Vector2i(2, 2)
	elif total <= 6:
		return Vector2i(3, 2)
	elif total <= 9:
		return Vector2i(3, 3)
	else:
		var cols := ceili(sqrt(float(total)))
		var rows := ceili(float(total) / float(cols))
		return Vector2i(cols, rows)


func _get_cell_size(grid: Vector2i, screen_rect: Rect2i) -> Vector2i:
	var w := (screen_rect.size.x - window_margin_gap * (grid.x - 1)) / grid.x
	var h := (screen_rect.size.y - window_margin_gap * (grid.y - 1)) / grid.y
	return Vector2i(w, h)


func _get_grid_position(instance_index: int, grid: Vector2i, screen_rect: Rect2i, cell_size: Vector2i) -> Vector2i:
	var col := instance_index % grid.x
	var row := instance_index / grid.x
	return Vector2i(
		screen_rect.position.x + col * (cell_size.x + window_margin_gap),
		screen_rect.position.y + row * (cell_size.y + window_margin_gap)
	)


# === Helpers de arquivo ===

func _read_sessions() -> Dictionary:
	if not FileAccess.file_exists(SESSION_FILE):
		return {}
	var f := FileAccess.open(SESSION_FILE, FileAccess.READ)
	if not f:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


func _write_sessions(sessions: Dictionary) -> void:
	var f := FileAccess.open(SESSION_FILE, FileAccess.WRITE)
	if not f:
		push_warning("[tile-run-instances] não conseguiu escrever ", SESSION_FILE)
		return
	f.store_string(JSON.stringify(sessions))
	f.close()


func _exit_tree() -> void:
	# Remove a si mesma do arquivo ao fechar
	var my_pid := OS.get_process_id()
	var sessions := _read_sessions()
	if sessions.erase(my_pid):
		_write_sessions(sessions)
