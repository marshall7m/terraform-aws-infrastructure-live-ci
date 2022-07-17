class ApprovalRequest:
    """Constructs the approval request message and stores the state of which votes were submitted."""

    WELCOME_BLOCK = {
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": (
                "Approval is needed for execution: <TODO>"
            ),
        },
    }
    DIVIDER_BLOCK = {"type": "divider"}

    def __init__(self, channel):
        self.channel = channel
        self.username = username
        self.icon_emoji = ":robot_face:"
        self.timestamp = ""
        self.approved_avatars = []
        self.reject_avatars = []

    def get_message_payload(self):
        return {
            "ts": self.timestamp,
            "channel": self.channel,
            "username": self.username,
            "icon_emoji": self.icon_emoji,
            "blocks": [
                self._get_metadata(),
                self.DIVIDER_BLOCK,
                *self._get_approved(),
                self.DIVIDER_BLOCK,
            ],
        }

    def _get_metadata(self):
        # TODO add PR initial description and actual Terraform plan to section?
        text = [
            (
                ":information_source: *<https://get.slack.help/hc/en-us/articles/206870317-Emoji-reactions|"
                "Pull Request>*"
            ),
            (
                ":information_source: *<https://get.slack.help/hc/en-us/articles/206870317-Emoji-reactions|"
                "ECS Task Logs>*"
            )
        ]
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": text
            }
        },
    
    def update_approved_avatars(self, avatar):
        return self.approved_avatars.append(avatar)

    def _get_approved(self):
        text = (
            f":thumbsup: *Approved:*\n{self.approved_avatars}"
        )
        return {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": text
            }
        }

    @staticmethod
    def _get_task_block(text, information):
        return [
            {"type": "section", "text": {"type": "mrkdwn", "text": text}},
            {"type": "context", "elements": [{"type": "mrkdwn", "text": information}]},
        ]