package words
import "core:math/rand"

Choice :: struct($T: typeid) {
	value:  T,
	chance: f64, // does not need to be 0-1, just a total overall frequency relative to other choices
}
rand_weighted_choice :: proc(choices: []Choice($T)) -> T {
	sum_chances: f64 = 0
	for c in choices {
		sum_chances += c.chance
	}
	spot := rand.float64_range(0, sum_chances)
	sum_chances = 0
	for c in choices {
		sum_chances += c.chance
		if sum_chances > spot {
			return c.value
		}
	}
	return choices[len(choices) - 1].value // shouldn't happen
}

get_word :: proc(
	min_difficulty: int = 0,
	max_difficulty: int = 100,
	min_length: int = 0,
	max_length: int = 1000,
) -> (
	string,
	bool,
) {
	choices := [dynamic]Choice(int){}
	for d in min_difficulty ..= max_difficulty {
		choice := Choice(int) {
			chance = 0,
			value  = d,
		}
		if d in WORDS_BY_DIFFICULTY {
			append(&choices, Choice(int){chance = f64(len(WORDS_BY_DIFFICULTY[d])), value = d})
		}
	}
	difficulty := rand_weighted_choice(choices[:])
	return get_word_with_difficulty(difficulty, min_length, max_length)
}
//TODO max attempts
get_word_with_difficulty :: proc(
	difficulty: int,
	min_length: int = 0,
	max_length: int = 1000,
) -> (
	string,
	bool,
) {

	if difficulty not_in WORDS_BY_DIFFICULTY {
		return "", false
	}
	for {
		word := rand.choice(WORDS_BY_DIFFICULTY[difficulty])
		if len(word) >= min_length && len(word) <= max_length {
			return word, true
		}
	}
}

get_left_hand_word :: proc(min_length: int = 0, max_length: int = 1000) -> string {
	for {
		word := rand.choice(LEFT_HAND_ONLY)
		if len(word) >= min_length && len(word) <= max_length {
			return word
		}
	}
}

get_right_hand_word :: proc(min_length: int = 0, max_length: int = 1000) -> string {
	for {
		word := rand.choice(RIGHT_HAND_ONLY)
		if len(word) >= min_length && len(word) <= max_length {
			return word
		}
	}
}
