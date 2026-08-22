# /// script
# requires-python = ">=3.11"
# dependencies = ["hypothesis==6.165.10"]
# ///

from hypothesis import given, settings, strategies as st


@settings(max_examples=1_000, derandomize=True, deadline=None)
@given(st.lists(st.integers()))
def test_priority_order_is_insertion_order(values):
    assert sorted(values) == values


if __name__ == "__main__":
    test_priority_order_is_insertion_order()
