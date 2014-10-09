# Description:
#   Notify users of comment mentions, issues/PRs assignments.
#
# Dependencies:
#   "githubot": "^1.0.0-beta2"
#   "lodash": "^2.4.1"
#
# Configuration:
#   HUBOT_GITHUB_TOKEN
#   HUBOT_GITHUB_USER for a default user, in case it is missing from a repository definition
#   HUBOT_GITHUB_USER_(.*) to map chat users to GitHub users
#
#   Put this url <HUBOT_URL>:<PORT>/hubot/gh-notify into your GitHub Webhooks
#   and enable 'issues', 'pull_request' and 'issue_comment' as events to receive.
#
# Commands:
#   hubot notify [me] [of] mentions [in <user/repo>] -- Registers the calling user for mentions in a repo's issues.
#   hubot notify [me] [of] assignments [in <user/repo>] -- Registers the calling user for issue assignments in a repo.
#   hubot notify [me] [of] (mentions|assignments) in <user/repo> -- Register the calling user for assignments or mentions in a repo.
#   hubot notify [me] [of] (mentions|assignments) in <repo> -- Register the calling user for assignments or mentions in a given repo IFF HUBOT_GITHUB_USER is configured.
#   hubot notify [me] [of] (mentions|assignments) -- Register the calling user for any assignment or mention (overrides all other assignment/mention notifications).
#   hubot unnotify [me] [from] (mentions|assignments) [in <user/repo>] - De-registers the calling user for mentions or assignments notifications of a repo.
#   hubot list [my] (mentions|assignments) notifications [in <user/repo>] -- Lists all mention or assignment notification subscriptions of the calling user in a repo.
#
# Author:
#   frapontillo

_ = require('lodash')

NOTIFY_REGEX = ///
  notify\s                          # Starts with 'notify'
  (me)?\s*                          # Optional 'me'
  (of)?\s*                          # Optional 'of'
  (mentions|assignments)\s*         # 'mentions' or 'assignments'
  (in\s\S+)?\s*                     # Optional 'in <user/repo>'
///i

UNNOTIFY_REGEX = ///
  unnotify\s                        # Starts with 'unnotify'
  (me)?\s*                          # Optional 'me'
  (from)?\s*                        # Optional 'from'
  (mentions|assignments)\s*         # 'mentions' or 'assignments'
  (in\s\S+)?\s*                     # Optional 'in <user/repo>'
///i

LIST_REGEX = ///
  list\s                            # Starts with 'list'
  (my)?\s*                          # Optional 'my'
  (mentions|assignments)\s*         # 'mentions' or 'assignments'
  notifications\s*                  # 'notifications'
  (in\s\S+)?\s*                     # Optional 'in <user/repo>'
///i

GITHUB_NOTIFY_PRE = 'github-notify-'

# Resolve user name to a potential GitHub username by using, in order:
#   - GitHub credentials as handled by the github-credentials.coffee script
#   - environment variables in the form of HUBOT_GITHUB_USER_.*
#   - the exact chat name
resolve_user = (user) ->
  name = user.name.replace('@', '')
  resolve_cred = (u) -> u.githubLogin
  resolve_env = (n) -> process.env["HUBOT_GITHUB_USER_#{n.replace(/\s/g, '_').toUpperCase()}"]
  resolve_cred(user) or resolve_env(name) or resolve_env(name.split(' ')[0]) or name

# Resolve all parameters for a given subscription/unsubscription request:
# chat user, qualified GitHub user, kind of notification, repository, qualified GitHub repository
resolve_params = (github, msg, kindPos, repoPos) ->
  kindPos = kindPos or 3
  repoPos = repoPos or 4
  user = msg.message.user
  kind = msg.match[kindPos]
  repo = msg.match[repoPos].replace('in ', '') if msg.match[repoPos]?

  qualified_repo = if not repo? then repo else github.qualified_repo repo
  qualified_user = resolve_user(msg.message.user)
  {
    user, qualified_user, kind, repo, qualified_repo
  }

# Add a notification to the user settings, checking that all other notifications of the same kind
# don't overlap with the new one (highest priority, same exact notification, etc.)
add_notification = (robot, params) ->
  # get all specific notifications of user
  userSettings = _.find(robot.brain.get(GITHUB_NOTIFY_PRE + params.kind), {userName: params.qualified_user}) or {}
  userNotifications = userSettings.userNotifications or []
  userInfo = userSettings.info or {}

  # if a global notification is already contained, throw an error
  if userNotifications.indexOf(true) >= 0
    throw new Error("You are already set to be notified for #{params.kind} in every repo.")

  # if the notification is already contained in the collection, throw an error
  if userNotifications.indexOf(params.qualified_repo) >= 0
    throw new Error("You are already set to be notified for #{params.kind} in #{params.qualified_repo}.")

  # if the notification is for every repo, remove all the notifications of the same kind
  if not params.qualified_repo?
    userNotifications = []

  # add the new notification
  userNotifications.push not params.repo? or params.qualified_repo
  # update the user information
  userInfo = params.user
  # build the new userSettings
  newUserSettings = {
    userName: params.qualified_user
    userNotifications: userNotifications,
    userInfo: userInfo
  }

  newSettings = robot.brain.get(GITHUB_NOTIFY_PRE + params.kind) or []
  _.remove(newSettings, {userName: params.qualified_user})
  newSettings.push(newUserSettings)

  # update the user info
  robot.brain.set GITHUB_NOTIFY_PRE + params.kind, newSettings

# Remove a notification from the user settings, if it exists, otherwise it throws an appropriate Error
remove_notification = (robot, params) ->
  # get all specific notifications of user
  userSettings = _.find(robot.brain.get(GITHUB_NOTIFY_PRE + params.kind), {userName: params.qualified_user}) or {}
  userNotifications = userSettings.userNotifications or []
  userInfo = userSettings.info or {}

  # if the notification is for every repo, remove all the notifications of the same kind
  if not params.qualified_repo?
    userNotifications.length = 0
    throw new Error("You have no notifications set up for #{params.kind}.") if deleted?.length <= 0
  else
    deleted = _.remove(userNotifications, params.qualified_repo)
    throw new Error("You have no notifications set up for #{params.kind} in #{params.qualified_repo}.") if deleted?.length <= 0

  # build the new userSettings
  newUserSettings = {
    userName: params.qualified_user
    userNotifications: userNotifications,
    userInfo: userInfo
  }

  newSettings = robot.brain.get(GITHUB_NOTIFY_PRE + params.kind) or []
  _.remove(newSettings, {userName: params.qualified_user})
  newSettings.push(newUserSettings)

  # update the user info
  robot.brain.set GITHUB_NOTIFY_PRE + params.kind, newSettings

# Handle a generic comment, it can be the first of the issue (the issue itself) or any next comment
on_commented_issue = (robot, comment, repository, users) ->
  userInfos = []
  # find all users that want to be notified of mentions
  for user in users
    userName = user.userName
    # match the repository first, as it usually is the easier check
    match_repo = user.userNotifications.indexOf(true) >= 0 or user.userNotifications.indexOf(repository.full_name) >= 0
    # after matching repo, also match for a mention
    if match_repo is true and comment.body.indexOf('@' + userName) >= 0
      userInfos.push user.userInfo
  # return the array
  userInfos

# Handle a generic comment, it can be the first of the issue (the issue itself) or any next comment
on_assigned_issue = (robot, assignee, repository, users) ->
  userInfos = []
  # find all users that want to be notified of mentions
  for user in users
    userName = user.userName
    # match the repository first, as it usually is the easier check
    match_repo = user.userNotifications.indexOf(true) >= 0 or user.userNotifications.indexOf(repository.full_name) >= 0
    # after matching repo, also match for a mention
    if match_repo is true and assignee.login is userName
      userInfos.push user.userInfo
  # return the array
  userInfos

module.exports = (robot) ->

  github = require('githubot')(robot)

  # handle notification subscriptions
  robot.respond NOTIFY_REGEX, (msg) ->
    params = resolve_params github, msg
    try
      add_notification(robot, params)
      robot.brain.save
      reply = "You will now receive notifications for #{params.kind} #{(if params.qualified_repo? then 'in ' + params.qualified_repo else 'everywhere')}."
    catch error
      reply = error
    robot.send params.user, reply

  # handle notification unsubscriptions
  robot.respond UNNOTIFY_REGEX, (msg) ->
    params = resolve_params github, msg
    try
      remove_notification(robot, params)
      robot.brain.save
      reply = "You will no longer receive notifications for #{params.kind} #{(if params.qualified_repo? then 'in ' + params.repo else 'anywhere')}."
    catch error
      reply = error
    robot.send params.user, reply

  # handle notification subscription listing
  robot.respond LIST_REGEX, (msg) ->
    params = resolve_params github, msg, 2
    # get the notifications
    userSettings = _.find(robot.brain.get(GITHUB_NOTIFY_PRE + params.kind), {userName: params.qualified_user}) or {}
    userNotifications = userSettings.userNotifications or []
    # build an appropriate response by joining all checked repositories
    if userNotifications?.length > 0
      s = _.map(userNotifications, (n) ->
        if n is true then 'every repository' else n
      ).join(', ')
      reply = "You will receive notifications for #{params.kind} in #{s}."
    else reply = "You will receive no notifications for #{params.kind}."
    robot.send params.user, reply

  # handle new comments and new issue assignments
  robot.router.post '/hubot/gh-notify', (req, res) ->
    payload = req.body
    # event can be issues, issue_comment, pull_request
    event = req.headers['x-github-event']

    # get users who subscribed for mentions
    mentions_users = robot.brain.get(GITHUB_NOTIFY_PRE + 'mentions')
    # get users who subscribed for assignments
    assignments_users = robot.brain.get(GITHUB_NOTIFY_PRE + 'assignments')

    # discriminate the payload according to the action type
    if (event is 'issues' and payload.action is 'opened')
      userInfos = on_commented_issue(robot, payload.issue, payload.repository, mentions_users)
      userInfos.forEach (userInfo) ->
        robot.send userInfo, "You have been mentioned in a new issue by #{payload.issue.user.login} in #{payload.repository.full_name}: #{payload.issue.html_url}."
    else if (event is 'issue_comment' and payload.action is 'created')
      userInfos = on_commented_issue(robot, payload.comment, payload.repository, mentions_users)
      userInfos.forEach (userInfo) ->
        robot.send userInfo, "You have been mentioned in a new comment by #{payload.comment.user.login} in #{payload.repository.full_name}: #{payload.comment.html_url}."
    else if (event is 'issues' and payload.action is 'assigned')
      userInfos = on_assigned_issue(robot, payload.assignee, payload.repository, assignments_users)
      userInfos.forEach (userInfo) ->
        robot.send userInfo, "You have been assigned to an issue in #{payload.repository.full_name}: #{payload.issue.html_url}."
    else if (event is 'pull_request' and payload.action is 'assigned')
      userInfos = on_assigned_issue(robot, payload.assignee, payload.repository, assignments_users)
      userInfos.forEach (userInfo) ->
        robot.send userInfo, "You have been assigned to a PR in #{payload.repository.full_name}: #{payload.issue.html_url}."

    res.send 'OK, YOLO'

