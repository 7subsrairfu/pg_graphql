select gql.resolve(
    $$
    query FirstNAccounts($first: Int!) {
      allAccounts(first: $first) {
        edges {
          node {
            id
          }
        }
      }
    }
    $$,
    '{"first": 2}'::jsonb
);

