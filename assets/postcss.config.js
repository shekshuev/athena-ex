module.exports = {
  plugins: {
    "@tailwindcss/postcss": {},
    "postcss-preset-env": {
      stage: 1,
      features: {
        "nesting-rules": true,
        "oklab-function": { preserve: true },
        "is-pseudo-class": false,
      },
      autoprefixer: {},
    },
  },
};
