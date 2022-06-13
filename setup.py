from setuptools import setup, find_packages

extras_require = {
    "precommit": ["sqlfluff", "shellcheck-py"],
    "unit": ["GitPython", "psycopg2-binary", "awscli", "boto3"],
    "integration": [
        "aurora-data-api",
        "psycopg2-binary",
        "GitPython",
        "awscli",
        "boto3",
        "pytest-regex-dependency",
    ],
}
extras_require["all"] = list(extras_require.values())

setup(
    name="terraform-aws-infrastructure-live",
    packages=find_packages(),
    extras_require=extras_require,
    description="Setup for testing environments",
)
