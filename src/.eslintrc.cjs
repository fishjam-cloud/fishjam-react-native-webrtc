/* eslint-disable no-undef */

module.exports = {
    extends: [
        'eslint:recommended',
        'plugin:@typescript-eslint/recommended',
        'prettier'
    ],
    parser: '@typescript-eslint/parser',
    plugins: ['@typescript-eslint', 'eslint-plugin-import'],
    root: true,
    overrides: [
        {
            files: ['*.ts', '*.tsx'],
            rules: {
                '@typescript-eslint/ban-ts-comment': 'off',
                '@typescript-eslint/no-explicit-any': 'off',
            }
        }
    ],
    rules: {
        'curly': 'error',
        'eqeqeq': 'error',
        'import/no-duplicates': 'error',
        'import/order': [
            'error',
            {
                'alphabetize': { 'order': 'asc' },
                'groups': [['builtin', 'external'], 'parent', 'sibling', 'index'],
                'newlines-between': 'always'
            }
        ],
        'no-nested-ternary': 'error',
    }
};
