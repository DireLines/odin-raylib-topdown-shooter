package words
//ways in which the entity can interact with the word / bullet system
WordProperty :: enum {
	speak, // speak the target word out loud?
	display_current_string, // display the current string on screen as text?
	accept_correct_letter, // if hit with the next letter in the target, add it to the string?
	accept_incorrect_letter, // if hit with a character besides the next letter in the target, add it to the string?
	reflect_correct_letter, // if hit with the next letter in the target, reflect it back as a bullet?
	reflect_incorrect_letter, // if hit with a character besides the next letter in the target, reflect it back as a bullet?
	clear_on_current_matches_target, // if current_string == target_word, delete this object?
	accept_commands, //if hit with "enter" bullet, submit it as a command?
	display_full_word, // display the entire target word on screen as text?
}
WordProperties :: bit_set[WordProperty]
//most enemies have a word they're speaking out loud which the player must fill in letter by letter. the wrong letter gets reflected back at the player
default_word_properties_enemy :: proc() -> WordProperties {
	return {
		.speak,
		.display_current_string,
		.display_full_word,
		.accept_correct_letter,
		.reflect_incorrect_letter,
		.clear_on_current_matches_target,
		.accept_commands,
	}
}
//most background objects such as walls and doors will not appear to interact with the word system at first glance.
//but they do, it's just not clear until the player modifies their properties a bit
//(say by making them speak, which is the intended way the player is supposed to realize)
default_word_properties_background_object :: proc() -> WordProperties {
	return {.accept_correct_letter, .clear_on_current_matches_target}
}
