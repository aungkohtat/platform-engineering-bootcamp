// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mermaid from 'astro-mermaid';
import starlightLinksValidator from 'starlight-links-validator';

export default defineConfig({
  site: 'https://aungkohtat.github.io',
  base: '/platform-engineering-bootcamp',
  integrations: [
    // must come before starlight so ```mermaid fences are rendered as diagrams
    mermaid({ theme: 'default', autoTheme: true }),
    starlight({
      title: 'Platform Engineering Bootcamp',
      description: 'Building an internal developer platform on Kubernetes, one component at a time.',
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/aungkohtat/platform-engineering-bootcamp' },
      ],
      editLink: {
        baseUrl: 'https://github.com/aungkohtat/platform-engineering-bootcamp/edit/main/',
      },
      lastUpdated: true,
      customCss: ['./src/styles/custom.css'],
      plugins: [starlightLinksValidator()],
      sidebar: [
        { label: 'Start here', items: [{ slug: 'index', label: 'Home' }, '00-intro-platform-engineering'] },
        { label: 'Modules', items: [{ autogenerate: { directory: 'modules' } }] },
      ],
    }),
  ],
});
