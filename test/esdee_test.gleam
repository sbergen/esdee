import checkmark
import envoy
import gleeunit
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn check_example_test() {
  assert checkmark.new(simplifile.read, simplifile.write)
    |> checkmark.file("README.md")
    |> checkmark.should_contain_contents_of(
      "./dev/esdee_dev.gleam",
      tagged: "gleam",
    )
    // Update locally, check on CI
    |> checkmark.check_or_update(
      when: envoy.get("GITHUB_WORKFLOW") == Error(Nil),
    )
    == Ok(Nil)
}
// All the functionality used by `discoverer`,
// so we focus on testing that.
