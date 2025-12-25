import checkmark
import envoy
import gleam/result
import gleeunit
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// All the functionality used by `discoverer`,
// so we focus on testing that.

/// Are we running on CI?
pub fn on_ci() -> Bool {
  result.is_ok(envoy.get("GITHUB_WORKFLOW"))
}

pub fn check_example_test() {
  assert checkmark.new(simplifile.read, simplifile.write)
    |> checkmark.document("README.md")
    |> checkmark.should_contain_contents_of(
      "./dev/esdee_dev.gleam",
      tagged: "gleam",
    )
    // Update locally, check on CI
    |> checkmark.check_or_update(when: !on_ci())
    == Ok(Nil)
}
