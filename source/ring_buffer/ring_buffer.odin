package ring_buffer

RingBuffer :: struct($T: typeid, $Size: int) {
	items: [Size]T,
	idx:   uint, //index of current item
}

init :: proc(buf: ^RingBuffer($T, $Size)) {
	for _, i in buf.items {
		buf.items[i] = T{}
	}
}

increment :: proc(buf: ^RingBuffer($T, $Size), slots: int = 1) -> (prev, curr: ^T) {
	prev = &buf.items[buf.idx]
	buf.idx = uint((int(buf.idx) + slots) %% len(buf.items))
	curr = &buf.items[buf.idx]
	return
}

get_current :: proc(buf: ^RingBuffer($T, $Size)) -> ^T {
	return &buf.items[buf.idx]
}

set_current :: proc(buf: ^RingBuffer($T, $Size), t: ^T) {
	buf.items[buf.idx] = t^
}

get_prev :: proc(buf: ^RingBuffer($T, $Size), slots_ago: int = 1) -> ^T {
	prev_idx := (int(buf.idx) - slots_ago) %% len(buf.items)
	return &buf.items[prev_idx]
}
