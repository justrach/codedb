class GitagentMcp < Formula
  desc "MCP server providing AI agents with structured GitHub operations"
  homepage "https://github.com/justrach/codedb"
  version "VERSION"
  license "AGPL-3.0-only"

  on_macos do
    on_arm do
      url "https://github.com/justrach/codedb/releases/download/vVERSION/gitagent-mcp-aarch64-macos"
      sha256 "SHA_ARM_MACOS"
    end
    on_intel do
      url "https://github.com/justrach/codedb/releases/download/vVERSION/gitagent-mcp-x86_64-macos"
      sha256 "SHA_X86_MACOS"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/justrach/codedb/releases/download/vVERSION/gitagent-mcp-aarch64-linux"
      sha256 "SHA_ARM_LINUX"
    end
    on_intel do
      url "https://github.com/justrach/codedb/releases/download/vVERSION/gitagent-mcp-x86_64-linux"
      sha256 "SHA_X86_LINUX"
    end
  end

  def install
    arch = Hardware::CPU.arm? ? "aarch64" : "x86_64"
    plat = OS.mac? ? "macos" : "linux"
    bin.install "gitagent-mcp-#{arch}-#{plat}" => "gitagent-mcp"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/gitagent-mcp --version 2>&1", 1)
  end
end
