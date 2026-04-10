package game
import "core:reflect"
import "core:slice"
import hm "handle_map_static"

//type safety on procs needing obj
GameObjectInst :: struct($T: typeid) {
	using obj: ^GameObject,
	using var: ^T,
}
get_object_from_ptr_typed :: proc(
	o: ^GameObject,
	$T: typeid,
) -> (
	GameObjectInst(T),
	bool,
) #optional_ok {
	if o == nil {
		print("nil pointer passed to", #procedure)
		return GameObjectInst(T){o, nil}, false
	}
	if o._variant_type != T {
		print(
			"object variant for",
			o.handle,
			"was expected to be",
			typeid_of(T),
			"but was",
			o._variant_type,
		)
		return GameObjectInst(T){o, nil}, false
	}
	return GameObjectInst(T){o, &o.variant.(T)}, true
}
get_object_from_handle_typed :: proc(
	h: GameObjectHandle,
	$T: typeid,
) -> (
	GameObjectInst(T),
	bool,
) #optional_ok {
	o, ok := hm.get(&game.objects, h)
	if !ok {
		print("invalid handle", h, "passed to", #procedure)
	}
	return get_object_from_ptr_typed(o, T)
}
get_object_from_handle_untyped :: proc(h: GameObjectHandle) -> (^GameObject, bool) #optional_ok {
	return hm.get(&game.objects, h)
}
get_object :: proc {
	get_object_from_handle_typed,
	get_object_from_ptr_typed,
	get_object_from_handle_untyped,
}

all_objects_with_tags :: proc(
	it: ^GameObjectsIterator,
	tags: ..ObjectTag,
) -> (
	val: ^GameObject,
	h: GameObjectHandle,
	has_next: bool,
) {
	tags := slice.enum_slice_to_bitset(tags, Tags)
	for obj, handle in hm.iter(it) {
		if obj.tags >= tags { 	//superset - object has all tags
			return obj, handle, true
		}
	}
	return
}

all_objects_with_variant :: proc(
	it: ^GameObjectsIterator,
	$variant_type: typeid,
) -> (
	val: GameObjectInst(variant_type),
	h: GameObjectHandle,
	has_next: bool,
) {
	for obj, h in hm.iter(it) {
		if obj._variant_type == variant_type {
			return {obj, &obj.variant.(variant_type)}, h, true
		}
	}
	return
}


GameObjectTypeAssert :: union {
	TagVariantAssert,
	TagTagAssert,
	TagCollisionLayerAssert,
}

//assert that some tag needs some union variant or vice versa
TagVariantAssert :: struct {
	tag:                                  ObjectTag,
	variant:                              typeid,
	tag_needs_variant, variant_needs_tag: bool,
}

//assert that some tag needs some other tag or vice versa
TagTagAssert :: struct {
	a, b:                 ObjectTag,
	a_needs_b, b_needs_a: bool,
}

TagCollisionLayerAssert :: struct {
	tag:                              ObjectTag,
	layer:                            CollisionLayer,
	tag_needs_layer, layer_needs_tag: bool,
}

//there are some type constraints I can't enforce using odin type system
//do some quick sanity checks
validate_object_types :: proc(asserts: []GameObjectTypeAssert = TYPE_ASSERTS) -> bool {
	valid := true
	it := hm.make_iter(&game.objects)
	for a in asserts {
		for obj, h in hm.iter(&it) {
			variant := reflect.union_variant_typeid(obj.variant)
			if variant != obj._variant_type {
				valid = false
				print(
					obj.handle,
					"(",
					obj.name,
					")",
					"has variant",
					variant,
					"but was created with variant",
					obj._variant_type,
					". changing variant after creation is not allowed",
				)
			}
			switch assertion in a {
			case TagVariantAssert:
				if assertion.tag_needs_variant &&
				   assertion.tag in obj.tags &&
				   variant != assertion.variant {
					valid = false
					print(
						obj.handle,
						"(",
						obj.name,
						")",
						"has tag",
						assertion.tag,
						"which needs state",
						assertion.variant,
						"but instead state is",
						variant,
					)
				}
				if assertion.variant_needs_tag &&
				   variant == assertion.variant &&
				   assertion.tag not_in obj.tags {
					valid = false
					print(
						obj.handle,
						"(",
						obj.name,
						")",
						"has state",
						assertion.variant,
						"which needs tag",
						assertion.tag,
						"but instead tags are",
						obj.tags,
					)
				}
			case TagTagAssert:
				if assertion.a_needs_b && assertion.a in obj.tags && assertion.b not_in obj.tags {
					valid = false
					print(
						obj.handle,
						"(",
						obj.name,
						")",
						"has tag",
						assertion.a,
						"which needs tag",
						assertion.b,
						"but instead tags are",
						obj.tags,
					)
				}
				if assertion.b_needs_a && assertion.b in obj.tags && assertion.a not_in obj.tags {
					valid = false
					print(
						obj.handle,
						"(",
						obj.name,
						")",
						"has tag",
						assertion.b,
						"which needs tag",
						assertion.a,
						"but instead tags are",
						obj.tags,
					)
				}
			case TagCollisionLayerAssert:
				//TODO: once multiple hitboxes, need to range over hitboxes
				if assertion.tag_needs_layer &&
				   assertion.tag in obj.tags &&
				   assertion.layer != obj.hitbox.layer {
					valid = false
					print(
						obj.handle,
						"(",
						obj.name,
						")",
						"has tag",
						assertion.tag,
						"which needs a hitbox with layer",
						assertion.layer,
						"but instead layer is",
						obj.hitbox.layer,
					)
				}
				if assertion.layer_needs_tag &&
				   assertion.layer == obj.hitbox.layer &&
				   assertion.tag not_in obj.tags {
					valid = false
					print(
						obj.handle,
						"(",
						obj.name,
						")",
						"has a hitbox with layer",
						assertion.layer,
						"which needs tag",
						assertion.tag,
						"but instead tags are",
						obj.tags,
					)
				}
			}
		}
	}
	return valid
}
