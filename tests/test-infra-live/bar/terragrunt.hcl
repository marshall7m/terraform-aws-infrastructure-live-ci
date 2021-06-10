terraform {
  source = ".//"
}

dependency "baz" {
  config_path = "../baz"
}

inputs = {
  dependency = dependency.baz.outputs.test
}