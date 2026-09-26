extends SkeletonModifier3D

# Добавка к позе рук при ходьбе: рука на стороне шагающей ноги чуть опускается.
# Работает ПОСЛЕ анимации покоя, поэтому не конфликтует с ней.

const DIP = 4.5            # на сколько опускается рука (в единицах кости, ~см)

var bones: Array = [-1, -1]     # индексы костей рук: [левая, правая]
var amount: Array = [0.0, 0.0]  # 0..1 для каждой руки
var last_set = {}
var last_off = {}

func _process_modification():
	var sk = get_skeleton()
	if sk == null:
		return
	for si in range(bones.size()):
		var idx = bones[si]
		if idx < 0:
			continue
		var cur = sk.get_bone_pose_position(idx)
		var base = cur
		# если анимация кость не трогала, убираем нашу прошлую добавку, чтобы она не копилась
		if last_set.has(idx) and cur.is_equal_approx(last_set[idx]):
			base = cur - last_off[idx]
		var off = Vector3(0.0, -DIP * amount[si], 0.0)
		sk.set_bone_pose_position(idx, base + off)
		last_set[idx] = base + off
		last_off[idx] = off
