import uuid

def dummy_tf_output():
    return f"""
    output "_{uuid.uuid4()}" {{
        value = "_{uuid.uuid4()}"
    }}
    """

def dummy_tf_provider_resource():
    return """
    provider "null" {}

    resource "null_resource" "this" {}
    """


def dummy_tf_github_repo(repo_name=f'dummy-repo-{uuid.uuid4()}'):
    return f"""
    terraform {{
    required_providers {{
        github = {{
        source  = "integrations/github"
        version = "4.9.3"
        }}
    }}
    }}
    provider "aws" {{}}

    data "aws_ssm_parameter" "github_token" {{
        name = "admin-github-token"
    }}

    provider "github" {{
        owner = "marshall7m"
        token = data.aws_ssm_parameter.github_token.value
    }}

    resource "github_repository" "dummy" {{
    name        = "{repo_name}"
    visibility  = "public"
    }}
    """