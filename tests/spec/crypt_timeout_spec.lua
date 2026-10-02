-- org-crypt doesn't wait forever for a gpg that hangs (e.g. one waiting
-- for a passphrase prompt it can't show).
local config = require("org.config")
local crypt = require("org.crypt")

describe("crypt with a gpg that doesn't answer", function()
  local timeout

  before_each(function()
    timeout = crypt.timeout
  end)

  after_each(function()
    crypt.timeout = timeout
    config.setup({})
  end)

  it("stops gpg after crypt.timeout and reports it", function()
    local dir = vim.fn.tempname()
    local gpg = fake_exe(dir, "fake-gpg", "sleep 10")
    config.setup({ crypt = { gpg_program = gpg } })
    crypt.timeout = 300
    local start = vim.uv.hrtime()
    local out, err = crypt.decrypt_string("-----BEGIN PGP MESSAGE-----\nx\n-----END PGP MESSAGE-----")
    eq(nil, out)
    ok(err and err:find("did not answer", 1, true), err)
    ok((vim.uv.hrtime() - start) / 1e6 < 5000, "stopped early")
  end)
end)
