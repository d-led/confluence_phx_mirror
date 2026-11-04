ExUnit.start()

# `--no-start`: the tests below are about logic that does not need the release's
# supervision tree, so nothing is started for them — except the two applications
# the code under test calls into, which in a running release are already up.
#
# `bandit`: one test asks the port decision a question over a real socket.
# `req`: the port decision asks a taken port who it is, with the same client the
# app uses. Both would otherwise answer "no process" and the test would be about
# the harness rather than the code.
{:ok, _started} = Application.ensure_all_started(:bandit)
{:ok, _started} = Application.ensure_all_started(:req)
