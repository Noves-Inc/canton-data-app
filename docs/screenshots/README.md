# Screenshot production

The authentication guides contain named screenshot slots instead of image links. Add a file
only after it has been captured from a Noves-controlled tenant and reviewed.

For every screenshot:

1. use synthetic hostnames and client names;
2. remove client IDs, tenant IDs, realm IDs, participant IDs, party IDs, tokens, and secrets;
3. crop to the controls described in `manifest.yaml`;
4. preserve enough navigation context for the reader to find the page;
5. save as WebP at twice the displayed width;
6. add the image reference beside the matching slot and update its manifest status.

Never use a customer tenant or a production credential in documentation screenshots.
