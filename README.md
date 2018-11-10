# GitHub-Event-Mailer
Webhook server sends transformed GitHub event JSON as email notifications. 

As stand-alone server:
```perl
GitHubEventMailer
  ->loadConfig("$ENV{HOME}/etc/GitHubWebhookRequest/config.cfg")
  ->start();
```

Or as `HTTP::Request`:
```perl
if ($r->isa('HTTP::Request')) {
    my $httpResponse = GitHubWebhookRequest->do($r);
}
```

Config:
```
[MAIN]
DEBUG_TO              = sdemuth@fairbanksllc.com
LISTEN                = 9999
SUPPRESS_NO_JOB_ERROR = 1
TEMPLATE_PATH         = ~/etc/GitHubWebhookRequest/templates/,

[PUSH_1]
event    = push
from     = from@address.com
template = push.tmpl
to       = to_1@address.com,to_2@address.com
secret   = SECRET

```

