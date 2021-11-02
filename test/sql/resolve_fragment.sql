select gql.dispatch($$
    {
      allBlogs(first: 1) {
        edges {
          cursor
          node {
            ...BaseBlog
            ownerId
          }
        }
      }
    }

    fragment BaseBlog on Blog {
      name
      description
    }
$$);
