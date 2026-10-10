const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  ...jestConfig,
  // sfdx-lwc-jest has no stub for lightning/modal
  moduleNameMapper: {
    "^lightning/modal$": "<rootDir>/jest-mocks/lightning/modal"
  },
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"]
};
