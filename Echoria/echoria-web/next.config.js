/** @type {import('next').NextConfig} */
const nextConfig = {
  // output: 'export', // Enable for production static deployment
  images: {
    unoptimized: true,
  },
  typescript: {
    tsconfigPath: './tsconfig.json',
  },
};

module.exports = nextConfig;
