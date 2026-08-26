locals {
  domain_name               = try(coalesce(var.api_gateway_custom_domain_name), null) // treat both "" and null as absent
  enable_custom_domain_name = local.domain_name == null ? false : true
  rds_env_vars = {
    RDS_DBNAME   = module.lambda_datastore.rds_db_name
    RDS_ENDPOINT = module.lambda_datastore.rds_instance_endpoint
    RDS_PASSWORD = var.rds_password
    RDS_URL      = module.lambda_datastore.rds_db_url
  }

  dynamodb_env_vars = {
    DYNAMODB_TABLE_NAME = module.lambda_datastore.dynamodb_table_name
  }

  s3_env_vars = {
    S3_BUCKET_NAME = module.lambda_datastore.s3_bucket_name
  }

  rds_env_vars_used      = var.enable_datastore && var.create_rds_instance ? local.rds_env_vars : {}
  dynamodb_env_vars_used = var.enable_datastore && var.create_dynamodb_table ? local.dynamodb_env_vars : {}
  s3_env_vars_used       = var.enable_datastore && var.create_s3_bucket ? local.s3_env_vars : {}

  datastore_env_vars = merge(local.rds_env_vars_used, local.dynamodb_env_vars_used, local.s3_env_vars_used)

  vpc_policy_required = contains(values(var.lambda_functions_config)[*].enable_vpc, true) ? true : false

  event_bus_name_env_var = {
    "INTRA_SERVICE_EVENT_BUS" : aws_cloudwatch_event_bus.internal.name,
    "ORG_EVENT_BUS" : lookup(var.event_bus_config, "org_event_bus_name", ""),
    "DOMAIN_EVENT_BUS" : lookup(var.event_bus_config, "domain_event_bus_name", "")
  }
  custom_policy_required = length(var.custom_policy_document) > 0 ? true : false
  tracing_config         = var.tracking_config
  enable_active_tracing  = local.tracing_config == "Active"

  app_layer_required = length(var.layer_artifact_key) > 0 ? true : false
  app_layer_count    = local.app_layer_required ? 1 : 0

  application_runtime   = var.application_runtime != "" ? var.application_runtime : null
  application_s3_key    = var.artifact_bucket_key != "" ? var.artifact_bucket_key : null
  application_image_uri = var.container_image_uri != "" ? "${var.container_image_uri}:${var.application_version}" : null

  application_layers = concat(
    local.app_layer_required ? [aws_lambda_layer_version.runtime_dependencies[0].arn] : [],
    var.additional_layers
  )

  function_package_type = {
    for function_key, function in var.lambda_functions_config :
    function_key => coalesce(function.package_type, var.application_package_type)
  }

  function_config = {
    for function_key, function in var.lambda_functions_config :
    function_key => {
      name         = format("%s-%s", var.application_name, function_key)
      package_type = local.function_package_type[function_key]
      is_zip       = local.function_package_type[function_key] == "Zip"
      is_image     = local.function_package_type[function_key] == "Image"

      runtime = function.runtime != null && function.runtime != "" ? function.runtime : local.application_runtime
      s3_key  = function.s3_key != null && function.s3_key != "" ? function.s3_key : local.application_s3_key

      // A function that declares layers declares the complete set: an explicit list
      // replaces the application list rather than adding to it, and an explicit empty
      // list means no layers. This keeps a layer built for one runtime or architecture
      // off a function that is neither.
      layers = function.layers != null ? function.layers : local.application_layers

      memory      = coalesce(function.function_memory, var.application_memory)
      timeout     = coalesce(function.function_timeout, var.application_timeout)
      concurrency = coalesce(function.function_concurrency_limit, -1)
    }
  }

  function_env_vars = merge(
    { APP_NAME = var.application_name },
    { PARAMETER_STORE_PATH = var.parameter_store_path },
    local.datastore_env_vars,
    local.event_bus_name_env_var,
    var.application_env_vars
  )

  service_catalog_application_count = var.create_service_catalog_application ? 1 : 0

  tags = merge(
    var.create_service_catalog_application ? { "awsApplication" : aws_servicecatalogappregistry_application.this[0].application_tag.awsApplication } : {},
    var.tags
  )
}

resource "aws_servicecatalogappregistry_application" "this" {
  count = local.service_catalog_application_count

  name        = var.application_name
  description = "${var.application_name} Lambda Application"
  tags        = var.tags
}

moved {
  from = aws_servicecatalogappregistry_application.this
  to   = aws_servicecatalogappregistry_application.this[0]
}

resource "aws_lambda_function" "lambda_application" {
  for_each = var.lambda_functions_config

  package_type = local.function_config[each.key].package_type

  s3_bucket     = local.function_config[each.key].is_zip ? var.artifact_bucket : null
  s3_key        = local.function_config[each.key].is_zip ? local.function_config[each.key].s3_key : null
  function_name = local.function_config[each.key].name
  description   = each.value.description
  role          = aws_iam_role.lambda_application_execution_role.arn
  handler       = local.function_config[each.key].is_zip ? each.value.handler : null

  image_uri = local.function_config[each.key].is_image ? local.application_image_uri : null

  publish     = true
  runtime     = local.function_config[each.key].is_zip ? local.function_config[each.key].runtime : null
  memory_size = local.function_config[each.key].memory
  timeout     = local.function_config[each.key].timeout

  reserved_concurrent_executions = local.function_config[each.key].concurrency

  layers = local.function_config[each.key].is_zip ? local.function_config[each.key].layers : null

  lifecycle {
    precondition {
      condition     = length(local.function_config[each.key].name) <= 64
      error_message = "Lambda function name \"${local.function_config[each.key].name}\" is ${length(local.function_config[each.key].name)} characters and AWS allows at most 64. Shorten application_name or the \"${each.key}\" key in lambda_functions_config."
    }

    precondition {
      condition     = !local.function_config[each.key].is_zip || local.function_config[each.key].runtime != null
      error_message = "Function \"${each.key}\" resolves to the Zip package type but has no runtime. Set runtime on its lambda_functions_config entry, or application_runtime for the whole application."
    }

    precondition {
      condition     = !local.function_config[each.key].is_zip || local.function_config[each.key].s3_key != null
      error_message = "Function \"${each.key}\" resolves to the Zip package type but has no artifact key. Set s3_key on its lambda_functions_config entry, or artifact_bucket_key for the whole application."
    }

    precondition {
      condition     = !local.function_config[each.key].is_image || local.application_image_uri != null
      error_message = "Function \"${each.key}\" resolves to the Image package type but no image URI is configured. Set container_image_uri for the application."
    }
  }

  tracing_config {
    mode = var.tracking_config
  }

  logging_config {
    log_format            = coalesce(each.value.log_format, "JSON")
    log_group             = aws_cloudwatch_log_group.lambda_application_log_group[each.key].name
    application_log_level = each.value.application_log_level
    system_log_level      = each.value.system_log_level
  }

  environment {
    variables = local.function_env_vars
  }

  dynamic "image_config" {
    for_each = local.function_config[each.key].is_image ? [true] : []
    content {
      command = [each.value.handler]
    }
  }

  dynamic "vpc_config" {
    for_each = each.value.enable_vpc ? [true] : []
    content {
      subnet_ids         = var.vpc_subnet_ids
      security_group_ids = var.vpc_security_group_ids
    }
  }

  dynamic "snap_start" {
    for_each = each.value.enable_snap_start ? [true] : []
    content {
      apply_on = "PublishedVersions"
    }
  }

  tags = local.tags
}

resource "aws_lambda_alias" "lambda_application_alias" {
  for_each = var.lambda_functions_config

  name             = var.alias_name
  description      = var.alias_description
  function_name    = aws_lambda_function.lambda_application[each.key].arn
  function_version = aws_lambda_function.lambda_application[each.key].version
}

resource "aws_lambda_layer_version" "runtime_dependencies" {
  count = local.app_layer_count

  layer_name = var.application_name

  s3_bucket   = var.artifact_bucket
  s3_key      = var.layer_artifact_key
  description = "External modules and application shared code"

  compatible_runtimes = [var.application_runtime]
}

