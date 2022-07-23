import logging
from pprint import pformat
import os
from slack_sdk.web import WebClient

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
class ApprovalRequest:
    """Constructs the approval request message and stores the state of which votes were submitted."""
    DIVIDER_BLOCK = {"type": "divider"}

    def __init__(
        self,
        channel,
        username,
        execution_id,
        cfg_path,
        timestamp="",
        slack_bot_token=os.environ.get('SLACK_BOT_TOKEN'),
        waiting_on_ids=[],
        approved_ids=[],
        rejection_ids=[]
    ):
        self.channel = channel
        self.username = username
        self.icon_emoji = ":robot_face:"
        self.timestamp = timestamp
        self.execution_id = execution_id
        self.cfg_path = cfg_path
        self.client = WebClient(token=slack_bot_token)
        self.waiting_on_ids = waiting_on_ids
        self.approved_ids = approved_ids
        self.rejection_ids = rejection_ids

    def get_message_payload(
        self,
        task_log_url=None,
        pr_url=None,
    ):
        return {
            "ts": self.timestamp,
            "channel": self.channel,
            "username": self.username,
            "icon_emoji": self.icon_emoji,
            "text": "IaC Approval Requested",
            "blocks": [
                self._get_header(),
                self.DIVIDER_BLOCK,
                self._get_context(),
                self.DIVIDER_BLOCK,
                self._get_links(task_log_url, pr_url),
                self.DIVIDER_BLOCK,
                *self._get_approved(),
                self.DIVIDER_BLOCK,
                *self._get_rejected(),
                self.DIVIDER_BLOCK,
                *self._get_waiting_on(),
                self.DIVIDER_BLOCK,
            ],
        }

    def _get_header(self): 
        return {
			"type": "header",
			"text": {
				"type": "plain_text",
				"text": "Infrastructure deployment needs approval",
				"emoji": True
			}
		}

    def _get_context(self):
        return {
			"type": "section",
			"fields": [
				{
					"type": "mrkdwn",
					"text": f"*Execution ID:*\n{self.execution_id}"
				},
				{
					"type": "mrkdwn",
					"text": f"*Directory:*\n{self.cfg_path}"
				}
			]
		}


    def _get_links(self, task_log_url, pr_url):
        # TODO add PR initial description and actual Terraform plan to section?
        return {
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": (
                        f":information_source: *<{pr_url}|"
                        "Pull Request>*"
                        )
                },
                {
                    "type": "mrkdwn",
                    "text": (
                        f":information_source: *<{task_log_url}|"
                        "ECS Task Logs>*"
                    )
                }
            ]
        }


    def update_approved_avatars(self, avatar):
        return self.approved_avatars.append(avatar)


    def _get_vote_section(self, header, ids, action):
        elements = []
        for id in ids:
            user = self.client.users_info(user=id)["user"]
            elements.append({
                "type": "image",
                "image_url": user["profile"]["image_24"],
                "alt_text": user["profile"]["display_name"]
            })

        count = len(ids)
        elements.append(
            {
                "type": "plain_text",
                "emoji": True,
                "text": (f"{count} voters" if count != 1 else f"{count} voter")
            },
        )

        return [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": header,
                },
                "accessory": {
                    "type": "button",
                    "text": {
                        "type": "plain_text",
                        "emoji": True,
                        "text": "Vote"
                    },
                    "value": action
                }
			},
            {
                "type": "context",
                "elements": elements
            },
        ]
    def _get_approved(self):
        return self._get_vote_section(
            ":thumbsup: *Approved:*",
            self.approved_ids,
            "approve"
        )


    def update_rejected_avatars(self, avatar):
        return self.rejected_avatars.append(avatar)


    def _get_rejected(self):
        return self._get_vote_section(
            ":thumbsdown: *Rejected:*",
            self.rejection_ids,
            "reject"
        )

    
    def update_waiting_on_avatars(self, avatar):
        return self.waiting_on_ids.append(avatar)


    def _get_waiting_on(self):
        return self._get_vote_section(
            ":inbox_tray: *Waiting on:*",
            self.waiting_on_ids,
            "wait_on"
        )

    @staticmethod
    def _get_section_mrkdwn(text):
        return {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": text
            }
        }
    
    def send_approval(self):
        message = self.get_message_payload()
        log.debug(f"Approval Message:\n{pformat(message)}")
        response = self.client.chat_postMessage(**message)

        log.debug("Updating approval message timestamp")
        self.timestamp = response.data["ts"]
        return response

    def expire_approval(self):
        """Adds expired label to approval message"""
        pass