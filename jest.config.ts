import type { Config } from 'jest';

const config: Config = {
    preset: 'ts-jest',
    testEnvironment: 'node',
    roots: ['<rootDir>/src'],
    testMatch: ['**/__tests__/**/*.test.ts'],
    moduleNameMapper: {
        '^react-native$': '<rootDir>/src/__mocks__/react-native.ts',
        '^react-native/Libraries/vendor/emitter/EventEmitter$':
            '<rootDir>/src/__mocks__/event-emitter.ts',
    },
    passWithNoTests: true,
};

export default config;
