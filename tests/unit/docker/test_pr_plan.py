import os
import logging
from unittest.mock import patch

from docker.src.pr_plan.plan import comment_pr_plan

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@patch("github.Github")
@patch.dict(
    os.environ,
    {"CFG_PATH": "terraform/cfg", "REPO_FULL_NAME": "user/repo", "PR_ID": "1"},
)
def test_comment_pr_plan(mock_gh):
    """Ensures comment_pr_plan() formats the comment's diff block properly and returns the expected comment"""
    plan = """

Changes to Outputs:
  - bar = "old" -> null
  + baz = "new"
  ~ foo = "old" -> "new"

You can apply this plan to save these new output values to the Terraform
state, without changing any real infrastructure.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.

"""
    expected = """
## Open PR Infrastructure Changes
### Directory: terraform/cfg
<details open>
<summary>Plan</summary>
<br>

``` diff


Changes to Outputs:
-   bar = "old" -> null
+   baz = "new"
!   foo = "old" -> "new"

You can apply this plan to save these new output values to the Terraform
state, without changing any real infrastructure.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.


```

</details>
"""
    actual = comment_pr_plan(plan)

    assert actual == expected
