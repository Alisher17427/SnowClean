extends SubViewport

# Маска очистки. Копки приходят очередью (свои и чужие) и рисуются кистями из пула:
# каждая кисть видна ровно один кадр, поэтому один взмах = один отпечаток.

@export var field_size = 64.0  # совпадает с Size у PlaneMesh снежного поля
@onready var clear_brush = $ClearBrush

const POOL_SIZE = 16
const OFFSCREEN = Vector2(-1000, -1000)
var pool: Array = []
var queue: Array = []

func _ready():
	clear_brush.position = OFFSCREEN
	pool.append(clear_brush)
	for i in range(POOL_SIZE - 1):
		var s = clear_brush.duplicate()
		add_child(s)
		pool.append(s)

func request_dig(world_pos: Vector3):
	var u = (world_pos.x + field_size / 2.0) / field_size
	var v = (world_pos.z + field_size / 2.0) / field_size
	queue.append(Vector2(u * size.x, v * size.y))

# полностью стирает накопленную маску расчистки (метель заново заносит двор снегом) -
# один раз включаем очистку кадра, дальше SubViewport сам вернёт Clear Mode Never
func reset_all():
	render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE

func _process(_delta):
	for s in pool:
		if queue.size() > 0:
			s.position = queue.pop_front()
		else:
			s.position = OFFSCREEN
