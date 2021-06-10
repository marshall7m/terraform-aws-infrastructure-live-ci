terraform {
  source = ".//"
}

dependency "bar" {
  config_path = "../bar"
}

inputs = {
  dependency = dependency.bar.outputs.test
}