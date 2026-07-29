# Screenshot production

The manifest records screenshots that may be added to the authentication guides. Add a file
only after capturing it from a Noves-controlled tenant and completing review.

For every screenshot:

1. use synthetic hostnames and client names;
2. remove client IDs, tenant IDs, realm IDs, participant IDs, party IDs, tokens, and secrets;
3. crop to the controls described in `manifest.yaml`;
4. preserve enough navigation context for the reader to find the page;
5. save as WebP at twice the displayed width;
6. add the image reference beside the matching slot and update its manifest status.

Never use a customer tenant or a production credential in documentation screenshots.
