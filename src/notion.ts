import { Client } from '@notionhq/client';
import * as dotenv from 'dotenv';

// Loading in the environment variables
dotenv.config(); 
const notion_api_key = process.env.NOTION_TOKEN;
const notion_db = process.env.NOTION_DATABASE_ID;

if (!notion_api_key || !notion_db) {
    throw new Error('Missing NOTION_TOKEN or NOTION_DATABASE_ID in .env');
}

const notion = new Client({ auth: notion_api_key });

//helper function to chunk text into 2000 character segments for Notion API
function chunkText(text: string, chunkSize: number = 2000): string[] {
    const chunks = [];
    for (let i = 0; i < text.length; i += chunkSize) {
        chunks.push(text.slice(i, i + chunkSize));
    }
    return chunks;
}

// helper function to format the content on the notion page
function buildBlocks(content: string){
    const lines = content.split('\n').filter(line => line.trim() !=='');

    return lines.flatMap((line): any[] => {
        if (line.startsWith('# ')){
            return [{
                object: 'block' as const,
                type: 'heading_1' as const,
                heading_1: {
                    rich_text: [{ text: { content: line.replace('# ', '').trim() } }]
                }
            }];
        } else if (line.startsWith('## ')){
            return [{
                object: 'block' as const,
                type: 'heading_2' as const,
                heading_2: {
                    rich_text: [{ text: { content: line.replace('## ', '').trim() } }]
                }
            }];
        } else if (line.startsWith('### ')){
            return [{
                object: 'block' as const,
                type: 'heading_3' as const,
                heading_3: {
                    rich_text: [{ text: { content: line.replace('### ', '').trim() } }]
                }
            }];
        } else if (line.startsWith('- ')) {
            return [{
                object: 'block' as const,
                type: 'bulleted_list_item' as const,
                bulleted_list_item: {
                    rich_text: [{ text: { content: line.replace('- ', '') } }]
                }
            }];
        } else {
            return chunkText(line).map(chunk => ({
                object: 'block' as const,
                type: 'paragraph' as const,
                paragraph: {
                    rich_text: [{ text: { content: chunk } }]
                }
            }));
        }
    });
}

async function createMeetingPage(title: string, date: string) {
    const response = await notion.pages.create({
        parent: { database_id: notion_db! },
        properties: {
            Name: {
                title: [ { text: { content: title } }]
            }, 
            Date: {
                rich_text: [ { text: { content: date } } ]
            }
        }
    });

    return response.id; // returns the page id of the newly created page
}

async function appendContentToPage(pageId: string, content: string) {
    const blocks = buildBlocks(content);

    for(let i = 0; i<blocks.length; i+=100){
        await notion.blocks.children.append({
            block_id: pageId,
            children: blocks.slice(i, i+100) as any
        });
    }
}


export { createMeetingPage, appendContentToPage };

/*
async function main() {

    // test data for creating a Notion page and appending content
    const pageId = await createMeetingPage('Project Kickoff Meeting', '2024-06-01');
    console.log('Created Notion page with ID:', pageId);

    const content = `## Summary
The project kickoff meeting was held on June 1st, 2024. The main objectives were to align on project goals, timelines, and responsibilities.

## Key Decisions
- The project will be completed in three phases: Planning, Execution, and Closure.
- The team will use Agile methodologies for project management.
- Weekly check-ins will be scheduled every Monday at 10 AM.

## Action Items
- John to create the project roadmap by June 5th.
- Jane to set up the project management tool by June 7th.
- Team to review the project requirements document by June 10th.

## Topics Discussed
- Project scope and deliverables
- Resource allocation and team roles
- Risk management strategies`;

    await appendContentToPage(pageId, content);
    console.log('Appended content to Notion page');
}   

main();
*/