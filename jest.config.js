module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/src/**/__tests__/**/*.test.ts'],
  modulePathIgnorePatterns: ['<rootDir>/lib/', '<rootDir>/example/'],
  transform: {
    '^.+\\.(ts|tsx)$': [
      'babel-jest',
      { presets: ['@react-native/babel-preset'] },
    ],
  },
};
