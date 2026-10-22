'use strict';
// Upwind image scan - Azure Pipelines task launcher (Node20, no dependencies).
// Maps task inputs (INPUT_<UPPERCASED-NAME> env vars) to the UPWIND_* contract
// of scan.sh, resolves the job token used for PR comments, runs scan.sh and
// propagates its exit code. Secret values are never printed.
const { spawnSync } = require('child_process');
const path = require('path');

const env = process.env;

// Boolean inputs may arrive as true/false/True/False (or 1/0/yes/no); scan.sh
// compares against the literal lowercase strings, so always export "true" or
// "false". Unrecognised values fall back to the default with a warning.
function bool(name, dflt) {
  const raw = (env[name] || '').trim().toLowerCase();
  // Empty/unset is indistinguishable here and means "not provided": default.
  if (raw === '') return dflt;
  if (raw === 'false' || raw === '0' || raw === 'no') return 'false';
  if (raw === 'true' || raw === '1' || raw === 'yes') return 'true';
  console.log('##vso[task.logissue type=warning]Unrecognised boolean value for ' + name + '; using default "' + dflt + '"');
  return dflt;
}

function str(name, dflt) {
  const raw = (env[name] || '').trim();
  return raw === '' ? dflt : raw;
}

function fail(message) {
  console.log('##vso[task.logissue type=error]' + message);
  console.log('##vso[task.complete result=Failed;]');
  process.exit(1);
}

const required = [
  ['dockerImage', 'INPUT_DOCKERIMAGE'],
  ['upwindClientId', 'INPUT_UPWINDCLIENTID'],
  ['upwindClientSecret', 'INPUT_UPWINDCLIENTSECRET'],
];
for (const [name, variable] of required) {
  if (str(variable, '') === '') fail('Input "' + name + '" is required');
}

const postComment = bool('INPUT_POSTCOMMENT', 'false');
const token = env.ENDPOINT_AUTH_PARAMETER_SYSTEMVSSCONNECTION_ACCESSTOKEN || env.SYSTEM_ACCESSTOKEN || '';
// Only PR runs that asked for a comment need the token; stay silent otherwise.
if (token === '' && postComment === 'true' && str('SYSTEM_PULLREQUEST_PULLREQUESTID', '') !== '') {
  console.log('##vso[task.logissue type=warning]No job access token available; the Upwind PR comment will be skipped. ' +
    'Grant the project build service identity "Contribute to pull requests" on the repository to enable it.');
}

const childEnv = Object.assign({}, env, {
  UPWIND_DOCKER_IMAGE: str('INPUT_DOCKERIMAGE', ''),
  UPWIND_CLIENT_ID: str('INPUT_UPWINDCLIENTID', ''),
  UPWIND_CLIENT_SECRET: str('INPUT_UPWINDCLIENTSECRET', ''),
  UPWIND_URI: str('INPUT_UPWINDURI', 'upwind.io'),
  UPWIND_BLOCK_ON: str('INPUT_BLOCKON', ''),
  UPWIND_ENFORCE_BLOCK_POLICY: bool('INPUT_ENFORCEBLOCKPOLICY', 'false'),
  UPWIND_FAIL_ON_SCAN_ERROR: bool('INPUT_FAILONSCANERROR', 'false'),
  UPWIND_DOCKER_PULL: bool('INPUT_DOCKERPULL', 'true'),
  UPWIND_DOCKER_USER: str('INPUT_DOCKERUSER', ''),
  UPWIND_DOCKER_PASSWORD: str('INPUT_DOCKERPASSWORD', ''),
  UPWIND_OCI_CLIENT: str('INPUT_OCICLIENT', 'docker'),
  UPWIND_ADDITIONAL_REGISTRIES: str('INPUT_ADDITIONALREGISTRIES', ''),
  UPWIND_MAIN_BRANCH: str('INPUT_MAINBRANCH', ''),
  UPWIND_AGENT_CHANNEL: str('INPUT_AGENTCHANNEL', 'stable'),
  UPWIND_POST_COMMENT: postComment,
  UPWIND_COMMENT_TOKEN: token,
});

const result = spawnSync('bash', [path.join(__dirname, 'scan.sh')], { stdio: 'inherit', env: childEnv });

let code = result.status;
if (code === null) {
  // Killed by a signal or failed to spawn.
  console.log('##vso[task.logissue type=error]scan.sh did not complete' + (result.error ? ': ' + result.error.message : ''));
  code = 1;
}
if (code !== 0) console.log('##vso[task.complete result=Failed;]');
process.exit(code);
