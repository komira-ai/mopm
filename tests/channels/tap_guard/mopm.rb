# This file is a copy of test/fixtures/mopm.rb of komira-ai/homebrew-tap, the formula that tap's path guard
# (.github/guard/guard.js) accepts: its template is an exact allow-list of the renderer's output, and this is that
# output for mopm 1.2.3, without a version line (the url carries it), with the checksums of tests/channels/fixtures/SHA256SUMS.
# Source: komira-ai/homebrew-tap at commit ef80a786ecbe9d63bc81a118bb1905519aeab04f (test/fixtures/mopm.rb).
# The comment lines above are not part of the file: tests/drivers/channels_cli_test.zig compares everything below them with what the
# release workflow's render command writes. When the guard's template changes, copy the new fixture here (and its commit above)
# and change tools/channels/formula.zig and the render command in .github/workflows/release.yml with it.
class Mopm < Formula
  desc "Package manager for Mojo"
  homepage "https://mopm.dev"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/komira-ai/mopm/releases/download/v1.2.3/mopm-1.2.3-macos-arm64.tar.gz"
      sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/komira-ai/mopm/releases/download/v1.2.3/mopm-1.2.3-linux-aarch64.tar.gz"
      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end
    on_intel do
      url "https://github.com/komira-ai/mopm/releases/download/v1.2.3/mopm-1.2.3-linux-x86_64.tar.gz"
      sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    end
  end

  def install
    bin.install "mopm"
  end

  test do
    assert_match "mopm #{version}", shell_output("#{bin}/mopm --version")
  end
end
