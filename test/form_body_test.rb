require "spinel_test/unit"
require "edgeway"

class FormBodyTest < SpinelTest::Unit::TestCase
  def decode(text)
    Edgeway::HTTP::FormBody.new(text).pairs
  end

  def test_empty_text_has_no_pairs
    assert_equal [], decode("")
  end

  def test_pairs_are_split_at_ampersands
    assert_equal [["a", "1"], ["b", "2"]], decode("a=1&b=2")
  end

  def test_semicolon_is_not_a_separator
    assert_equal [["a", "1;b=2"]], decode("a=1;b=2")
  end

  def test_trailing_ampersand_adds_no_pair
    assert_equal [["a", ""]], decode("a&")
    assert_equal [["", ""]], decode("&")
  end

  def test_empty_pair_between_ampersands_is_kept
    assert_equal [["a", "b"], ["", ""], ["c", "d"]], decode("a=b&&c=d")
    assert_equal [["a", ""], ["", ""]], decode("a&&")
  end

  def test_pair_without_equals_has_an_empty_value
    assert_equal [["a", ""]], decode("a")
    assert_equal [["a", ""]], decode("a=")
  end

  def test_pair_with_only_a_value_has_an_empty_key
    assert_equal [["", "b"]], decode("=b")
    assert_equal [["", ""]], decode("=")
  end

  def test_equals_inside_the_value_is_kept
    assert_equal [["a", "b=c"]], decode("a=b=c")
    assert_equal [["a", "="]], decode("a==")
  end

  def test_plus_is_a_space_in_keys_and_values
    assert_equal [["a b", "c d"]], decode("a+b=c+d")
  end

  def test_escaped_plus_is_a_plus
    assert_equal [["a", "+"]], decode("a=%2B")
  end

  def test_escapes_are_decoded_in_either_case
    assert_equal [["A", "JJ"]], decode("%41=%4a%4A")
  end

  def test_percent_escape_is_decoded_once
    assert_equal [["a", "%41"]], decode("a=%2541")
  end

  def test_invalid_escapes_are_kept
    assert_equal [["%", ""]], decode("%")
    assert_equal [["%4", ""]], decode("%4")
    assert_equal [["%zz", ""]], decode("%zz")
    assert_equal [["a", "%zz%4"]], decode("a=%zz%4")
  end

  def test_utf8_escapes_are_decoded
    assert_equal [["あ", "あ"]], decode("%e3%81%82=%E3%81%82")
  end

  def test_bytes_that_are_not_utf8_become_replacement_characters
    assert_equal [["�", ""]], decode("%ff")
    assert_equal [["a", "�"]], decode("a=%e3%81")
  end

  def test_sent_replacement_character_is_kept
    assert_equal [["a", "�"]], decode("a=%ef%bf%bd")
  end

  def test_results_are_valid_utf8
    pair = decode("%ff=%e3%81%82").first
    pair.each do |string|
      assert_equal true, string.valid_encoding?
      assert_equal "UTF-8", string.encoding.to_s
    end
  end

  def test_raw_utf8_is_kept
    assert_equal [["a", "あ"]], decode("a=あ")
  end

  def test_escaped_nul_is_decoded
    assert_equal [["a", "\u0000"]], decode("a=%00")
  end
end
