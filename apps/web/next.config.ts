import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  async redirects() {
    return [
      {
        source: "/install",
        destination:
          "https://raw.githubusercontent.com/unlaboredlabs/xaq/main/install.sh",
        permanent: false,
      },
    ];
  },
};

export default nextConfig;
