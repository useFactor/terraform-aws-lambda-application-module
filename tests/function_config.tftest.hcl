provider "aws" {
  region = "us-west-2"
}

variables {
  application_name    = "test-lambda-app"
  application_runtime = "nodejs18.x"
  application_version = "1.0.0"
  artifact_bucket     = "test-artifact-bucket"
  artifact_bucket_key = "test-app.zip"

  additional_layers = ["arn:aws:lambda:us-west-2:123456789012:layer:app-shared:3"]

  lambda_functions_config = {
    api = {
      handler     = "api/index.handler"
      enable_vpc  = false
      description = "API handler function"
    }
    worker = {
      handler     = "worker/index.handler"
      enable_vpc  = false
      description = "Background worker function"
    }
  }

  tags = {
    Environment = "test"
  }
}

run "functions_declaring_no_overrides_inherit_every_application_wide_value" {
  command = plan

  assert {
    condition = alltrue([
      for function in values(aws_lambda_function.lambda_application) :
      function.package_type == "Zip"
    ])
    error_message = "Functions declaring no package_type should take the application package type"
  }

  assert {
    condition = alltrue([
      for function in values(aws_lambda_function.lambda_application) :
      function.runtime == "nodejs18.x"
    ])
    error_message = "Functions declaring no runtime should take application_runtime"
  }

  assert {
    condition = alltrue([
      for function in values(aws_lambda_function.lambda_application) :
      length(function.layers) == 1 && function.layers[0] == "arn:aws:lambda:us-west-2:123456789012:layer:app-shared:3"
    ])
    error_message = "Functions declaring no layers should take the application layer list"
  }

  assert {
    condition = alltrue([
      for function in values(aws_lambda_function.lambda_application) :
      function.s3_bucket == "test-artifact-bucket" && function.s3_key == "test-app.zip"
    ])
    error_message = "Functions declaring no s3_key should take artifact_bucket_key from the application"
  }

  assert {
    condition = alltrue([
      for function in values(aws_lambda_function.lambda_application) :
      function.memory_size == 128 && function.timeout == 3
    ])
    error_message = "Functions declaring no memory or timeout should take the application defaults"
  }

  assert {
    condition = alltrue([
      for function in values(aws_lambda_function.lambda_application) :
      function.reserved_concurrent_executions == -1
    ])
    error_message = "Functions declaring no concurrency limit should be unreserved"
  }
}

run "per_function_runtime_overrides_the_application_runtime" {
  command = plan

  variables {
    lambda_functions_config = {
      api = {
        handler    = "api/index.handler"
        enable_vpc = false
      }
      reporter = {
        handler    = "reporter/index.handler"
        enable_vpc = false
        runtime    = "python3.12"
      }
    }
  }

  assert {
    condition     = aws_lambda_function.lambda_application["reporter"].runtime == "python3.12"
    error_message = "A function declaring a runtime should use it"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["api"].runtime == "nodejs18.x"
    error_message = "A function declaring no runtime should be unaffected by another function's override"
  }
}

run "zip_function_inside_an_image_application" {
  command = plan

  variables {
    application_package_type = "Image"
    application_runtime      = ""
    container_image_uri      = "123456789012.dkr.ecr.us-west-2.amazonaws.com/my-lambda-image"

    lambda_functions_config = {
      api = {
        handler    = "api/index.handler"
        enable_vpc = false
      }
      reporter = {
        handler      = "reporter/index.handler"
        enable_vpc   = false
        package_type = "Zip"
        runtime      = "python3.12"
        s3_key       = "reporter.zip"
      }
    }
  }

  assert {
    condition     = aws_lambda_function.lambda_application["api"].package_type == "Image"
    error_message = "A function declaring no package type should stay on the application package type"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["reporter"].package_type == "Zip"
    error_message = "A function declaring the Zip package type should use it inside an Image application"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["reporter"].runtime == "python3.12"
    error_message = "A Zip function inside an Image application should use its own runtime"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["reporter"].s3_bucket == "test-artifact-bucket"
    error_message = "A Zip function should resolve its artifact from the application artifact bucket"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["reporter"].s3_key == "reporter.zip"
    error_message = "A Zip function should use its own artifact key"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["reporter"].handler == "reporter/index.handler"
    error_message = "A Zip function should set handler rather than an image command"
  }

  assert {
    condition     = length(aws_lambda_function.lambda_application["reporter"].image_config) == 0
    error_message = "A Zip function should have no image configuration"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["api"].image_uri == "123456789012.dkr.ecr.us-west-2.amazonaws.com/my-lambda-image:1.0.0"
    error_message = "An Image function should keep the application image URI"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["api"].image_config[0].command[0] == "api/index.handler"
    error_message = "An Image function should pass its handler as the image command"
  }
}

run "per_function_layers_replace_the_application_layer_list" {
  command = plan

  variables {
    lambda_functions_config = {
      api = {
        handler    = "api/index.handler"
        enable_vpc = false
      }
      reporter = {
        handler    = "reporter/index.handler"
        enable_vpc = false
        runtime    = "python3.12"
        layers     = ["arn:aws:lambda:us-west-2:123456789012:layer:reporter-deps:1"]
      }
    }
  }

  assert {
    condition = length(aws_lambda_function.lambda_application["reporter"].layers) == 1 && aws_lambda_function.lambda_application["reporter"].layers[0] == "arn:aws:lambda:us-west-2:123456789012:layer:reporter-deps:1"

    error_message = "A function declaring layers should receive exactly those, not those merged with the application list"
  }

  assert {
    condition = length(aws_lambda_function.lambda_application["api"].layers) == 1 && aws_lambda_function.lambda_application["api"].layers[0] == "arn:aws:lambda:us-west-2:123456789012:layer:app-shared:3"

    error_message = "A function declaring no layers should still receive the application layer list"
  }
}

run "an_empty_per_function_layer_list_means_no_layers" {
  command = plan

  variables {
    lambda_functions_config = {
      api = {
        handler    = "api/index.handler"
        enable_vpc = false
      }
      reporter = {
        handler    = "reporter/index.handler"
        enable_vpc = false
        layers     = []
      }
    }
  }

  assert {
    condition     = length(aws_lambda_function.lambda_application["reporter"].layers) == 0
    error_message = "A function declaring an empty layer list should receive no layers"
  }

  assert {
    condition     = length(aws_lambda_function.lambda_application["api"].layers) == 1
    error_message = "One function opting out of layers should not remove them from the rest"
  }
}

run "per_function_memory_and_timeout_override_the_application_values" {
  command = plan

  variables {
    application_memory  = 512
    application_timeout = 30

    lambda_functions_config = {
      api = {
        handler    = "api/index.handler"
        enable_vpc = false
      }
      reporter = {
        handler          = "reporter/index.handler"
        enable_vpc       = false
        function_memory  = 2048
        function_timeout = 120
      }
    }
  }

  assert {
    condition     = aws_lambda_function.lambda_application["reporter"].memory_size == 2048
    error_message = "A function declaring memory should override the application value"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["reporter"].timeout == 120
    error_message = "A function declaring a timeout should override the application value"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["api"].memory_size == 512
    error_message = "A function declaring no memory should take application_memory"
  }

  assert {
    condition     = aws_lambda_function.lambda_application["api"].timeout == 30
    error_message = "A function declaring no timeout should take application_timeout"
  }
}

run "a_zip_function_without_a_runtime_fails_at_plan" {
  command = plan

  variables {
    application_runtime = ""

    lambda_functions_config = {
      api = {
        handler    = "api/index.handler"
        enable_vpc = false
      }
    }
  }

  expect_failures = [aws_lambda_function.lambda_application]
}

run "a_zip_function_without_an_artifact_key_fails_at_plan" {
  command = plan

  variables {
    artifact_bucket_key = ""

    lambda_functions_config = {
      api = {
        handler    = "api/index.handler"
        enable_vpc = false
      }
    }
  }

  expect_failures = [aws_lambda_function.lambda_application]
}

run "an_image_function_without_an_image_uri_fails_at_plan" {
  command = plan

  variables {
    application_package_type = "Image"
    container_image_uri      = ""

    lambda_functions_config = {
      api = {
        handler    = "api/index.handler"
        enable_vpc = false
      }
    }
  }

  expect_failures = [aws_lambda_function.lambda_application]
}

# application_name (15) + "-" + key (50) = 66 characters, over the AWS limit of 64.
run "a_function_name_over_the_aws_limit_fails_at_plan" {
  command = plan

  variables {
    lambda_functions_config = {
      "a-deliberately-long-function-key-for-the-name-test" = {
        handler    = "index.handler"
        enable_vpc = false
      }
    }
  }

  expect_failures = [aws_lambda_function.lambda_application]
}

run "an_unrecognised_per_function_package_type_is_rejected" {
  command = plan

  variables {
    lambda_functions_config = {
      api = {
        handler      = "api/index.handler"
        enable_vpc   = false
        package_type = "zip"
      }
    }
  }

  expect_failures = [var.lambda_functions_config]
}
