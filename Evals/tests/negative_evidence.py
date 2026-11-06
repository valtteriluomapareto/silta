"""Independent negative evidence for each grader predicate, derived from real replays."""

def invalidate(e, key):
    phases = e['phases']
    final = phases[-1]['state']
    if key == 'stream_complete':
        phases[0]['complete'] = False
    elif key == 'agent_logs':
        phases[0]['logs'] = []
    elif key == 'brief_used':
        for phase in phases:
            phase['logs'] = [l for l in phase['logs'] if l['command'] not in ('silta brief', 'silta agents session-start')]
    elif key == 'task_started':
        for phase in phases:
            phase['logs'] = [l for l in phase['logs'] if l['command'] != 'silta task start']
    elif key == 'backend_read':
        phases[0]['tool_results'] = []
    elif key == 'no_forbidden':
        phases[0]['commands'].append('gh issue create --title Acme')
    elif key == 'no_plan_files':
        final['files']['acme-mobile/notes.md'] = 'new-plan'
    elif key == 'plan_stored':
        final['tasks'][0]['plan_rev'] = 0
    elif key == 'handoff_written':
        phases[0]['state']['comments'] = []
    elif key == 'resume_brief_first':
        phases[1]['logs'] = phases[1]['logs'][1:]
    elif key == 'resume_task':
        phases[1]['actor'] = phases[0]['actor']
    elif key == 'resume_no_replan':
        final['plans'].append({'task_id': 1, 'rev': 2, 'body_md': 'Replanned'})
    elif key == 'result_template':
        final['tasks'][0]['result_md'] = 'Done!'
    elif key == 'result_sha':
        final['tasks'][0]['done_sha'] = 'f' * 40
    elif key == 'proposal_rows':
        final['tasks'][-1]['status'] = 'proposed'
    elif key == 'approval_provenance':
        e['approval']['words'] = 'Invented by the model.'
    elif key == 'existing_proposal':
        final['tasks'][1]['status'] = 'todo'
    elif key == 'own_parent':
        final['tasks'][-1]['parent_id'] = 3
    elif key == 'absent_idea':
        for comment in final['comments']:
            comment['body_md'] = 'No remaining work.'
    elif key == 'policy_choice':
        final['comments'] = [c for c in final['comments'] if c['kind'] != 'decision']
    elif key == 'policy_brief':
        e['controls']['tiny']['data']['settings'] = {}
    elif key == 'policy_guide':
        e['controls']['guide'] = 'workspace-dependent guide'
    elif key == 'policy_gate':
        e['controls']['gate']['error']['code'] = 'invalid'
    elif key == 'evidence_review':
        e['review'] = None
    else:
        raise AssertionError(key)
