import unittest
from numeric_score import entities, compare
from score import errors


class NumericMeaningTest(unittest.TestCase):
    def same(self, reference, hypothesis):
        result = compare(reference, hypothesis, errors)
        self.assertFalse(result["review_required"], result)
        self.assertTrue(result["exact_match"], result)
        self.assertEqual(result["errors"], 0)

    def different(self, reference, hypothesis):
        result = compare(reference, hypothesis, errors)
        self.assertFalse(result["exact_match"], result)
        self.assertGreater(result["errors"], 0)

    def test_cardinal_formatting_and_units(self):
        for reference, hypothesis in [
            ("2,000 calories", "two thousand calories"),
            ("a hundred square feet", "100 square feet"),
            ("an hour", "one hour"),
            ("the nineties", "the 90s"),
            ("2.5 million dollars", "two million five hundred thousand dollars"),
            ("5°C", "five degrees celsius"),
            ("2000 calories", "two thousand calories"),
            ("150 dollars", "one hundred and fifty dollars"),
            ("$150", "one hundred fifty dollars"),
            ("50%", "fifty percent"),
            ("7-day plan", "seven day plan"),
            (
                "1,234,567",
                "one million two hundred thirty four thousand five hundred sixty seven",
            ),
            ("1.25 kilograms", "one point two five kg"),
            ("-5 grams", "negative five grams"),
        ]:
            with self.subTest(reference=reference):
                self.same(reference, hypothesis)

    def test_value_unit_sign_and_negation_are_not_erased(self):
        for reference, hypothesis in [
            ("7-day plan", "70 meal plan"),
            ("7 days", "seven weeks"),
            ("5 dollars", "five cents"),
            ("50%", "fifty"),
            ("-5", "5"),
            ("1.25", "1.52"),
            ("5 million", "5 billion"),
            ("5°C", "5°F"),
            ("5 feet", "five meters"),
            ("$5", "€5"),
        ]:
            self.different(reference, hypothesis)
        # This auxiliary metric does not judge nonnumeric intent. Strict WER does.
        self.assertEqual(errors(["do", "not", "save", "5"], ["do", "save", "5"]), 1)

    def test_identifier_digits_preserve_leading_zeros_and_order(self):
        self.same(
            "phone number 0123456789",
            "phone number zero one two three four five six seven eight nine",
        )
        self.same(
            "phone number 555-123-4567",
            "phone number five five five one two three four five six seven",
        )
        self.same("order number 124", "order number one hundred twenty four")
        self.same("extension number 345", "extension number three-four-five")
        self.same("number ending in 7810", "number ending in seven eight one zero")
        self.different("order number 0123", "order number 123")
        self.different("phone number 1234", "phone number one two four three")
        uncertain = compare(
            "flight number 783", "flight number seven eighty three", errors
        )
        self.assertTrue(uncertain["review_required"])
        self.assertFalse(uncertain["exact_match"])

    def test_ordinals_dates_and_times(self):
        for reference, hypothesis in [
            ("the 22nd", "the twenty-second"),
            ("September 22", "the twenty second of September"),
            ("September 22, 2026", "2026-09-22"),
            ("8:30 pm", "eight thirty p.m."),
            ("8:00 am", "eight a m"),
            ("12:30 pm", "twelve thirty pm"),
            ("at 8:30", "at eight thirty"),
        ]:
            self.same(reference, hypothesis)
        self.different("8:00 am", "8:00 pm")
        self.different("the 22nd", "the 20-second")
        self.different("September 22", "October 22")
        self.different("September 2026", "October 2026")
        self.assertTrue(entities("2026-02-30")[1])
        self.assertTrue(entities("9/10/2026")[1])

    def test_missing_and_hallucinated_numbers_remain_errors(self):
        result = compare("deliver 2 items for 20 dollars", "", errors)
        self.assertEqual(result["reference_entity_count"], 2)
        self.assertEqual(result["errors"], 2)
        self.different("hello", "hello 100")
        self.different("2 coffees and 3 teas", "3 coffees and 2 teas")
        self.assertTrue(entities("half a liter")[1])


if __name__ == "__main__":
    unittest.main()
