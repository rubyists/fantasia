Work only on the current phase: {{ issue.identifier }} — {{ issue.title }}.

{% if issue.description %}
Issue description:
{{ issue.description }}
{% else %}
No description was provided.
{% endif %}
