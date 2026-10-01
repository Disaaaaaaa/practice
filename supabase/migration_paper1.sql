-- Migration: multi-assignment submissions/mark_scheme + "Paper 1 2023" mock exam.
-- Run this once in the Supabase SQL editor. Idempotent (safe to re-run).

-- ---------- make submissions/mark_scheme assignment-aware ----------
-- Previously a student had exactly one submissions row total (unique on
-- student_id alone), which only worked because there was a single
-- assignment. Now there can be several, so submissions are keyed by
-- (student_id, assignment_id) instead.

alter table public.mark_scheme add column if not exists assignment_id uuid references public.assignments(id);

update public.mark_scheme
set assignment_id = (select id from public.assignments where slug = 'web-page-design-theory')
where assignment_id is null;

alter table public.mark_scheme alter column assignment_id set not null;

alter table public.submissions add column if not exists assignment_id uuid references public.assignments(id);

update public.submissions
set assignment_id = (select id from public.assignments where slug = 'web-page-design-theory')
where assignment_id is null;

alter table public.submissions alter column assignment_id set not null;

alter table public.submissions drop constraint if exists submissions_student_id_key;
alter table public.submissions drop constraint if exists submissions_student_id_assignment_id_key;
alter table public.submissions add constraint submissions_student_id_assignment_id_key unique (student_id, assignment_id);

-- Tighten the mark_scheme RLS policy now that there's more than one
-- assignment: a student submitting assignment A should not be able to read
-- assignment B's mark scheme just because *some* submission of theirs is
-- marked submitted. (The Node server was already scoping this correctly;
-- this closes the same gap at the RLS layer too.)
drop policy if exists "mark_scheme_select" on public.mark_scheme;
create policy "mark_scheme_select" on public.mark_scheme
  for select using (
    public.is_teacher()
    or exists (
      select 1 from public.submissions s
      where s.student_id = auth.uid()
        and s.assignment_id = mark_scheme.assignment_id
        and s.submitted = true
    )
  );

-- ---------- Paper 1 2023 (NIS Grade 12 Computer Science, May 2023, 70 marks) ----------
insert into public.assignments (slug, title, type) values
  ('paper-1-2023', 'Paper 1 2023', 'mock_exam')
on conflict (slug) do nothing;

insert into public.class_assignments (class_name, assignment_id, is_open)
select c.name, a.id, false
from public.classes c
cross join public.assignments a
where a.slug = 'paper-1-2023'
on conflict (class_name, assignment_id) do nothing;

insert into public.mark_scheme (id, assignment_id, question, max_marks, points, model_answer)
select v.id, a.id, v.question, v.max_marks, v.points::jsonb, v.model_answer
from (select id from public.assignments where slug = 'paper-1-2023') a,
(values
  ('p1_1a', 'Convert the binary integer 01011011 to denary.', 1,
    '["Denary: 91 (64+16+8+2+1). 1 mark for correct answer only."]', null::text),
  ('p1_1b', 'Convert the binary integer 01011011 to hexadecimal.', 1,
    '["Hexadecimal: 5B. 1 mark for correct answer only."]', null),
  ('p1_1c', 'Perform subtraction of the 8-bit binary number 00100111 from 01001001 using two''s complement. Show your working.', 3,
    '["Convert 00100111 to its two''s complement (negative) form: 11011001. [1 mark]","Add 01001001 + 11011001 = 100100010. [1 mark]","Subtraction result, dropping the overflow bit: 00100010 (accept 0100010). [1 mark]"]', null),
  ('p1_1d', 'Convert the denary number 17.75 into binary using normalised floating-point representation with 10 bits for the mantissa and 6 bits for the exponent, both expressed in two''s complement.', 4,
    '["17.75 in binary is 10001.11.","Normalised form is 0.1000111 x 2^5.","Mantissa (10 bits): 1000111000 — 1 mark for working out the mantissa.","Exponent (6-bit two''s complement) is 5: 000101 — 1 mark for the correct exponent.","1 further mark for correctly normalising the number; 1 further mark for overall correct final answer."]',
    '17.75 = 10001.11 (binary)
Normalised: 0.1000111 x 2^5
Mantissa (10 bits): 1000111000
Exponent (6-bit two''s complement): 000101'),
  ('p1_2', 'Explain the difference between data verification and validation.', 2,
    '["Validation: checking data is sensible/reasonable/clean and useful before it is accepted; checking the inputs to the system. [1 mark]","Verification: checking a copy of data is exactly equal to the original copy; carried out on copies/backups of data. [1 mark]","Any correctly explained difference between the two terms also earns both marks."]', null),
  ('p1_3a', 'Describe what blockchain technology is.', 1,
    '["A distributed database/ledger shared among the nodes of a computer network.","A growing list of records (blocks) linked together using cryptography.","A technology for maintaining a secure and decentralised record of transactions.","Accept any one reasonable description. Max 1 mark."]', null),
  ('p1_3b', 'Give one example of using blockchain technology.', 1,
    '["Cryptocurrencies/Bitcoin/Ethereum, smart contracts, financial services, games, supply chain, domain names — accept any correct example. Max 1 mark."]', null),
  ('p1_4a', 'Describe how encryption protects private information.', 1,
    '["The data is stored in a scrambled form.","Data is not understandable without the key.","Accept either point. Max 1 mark."]', null),
  ('p1_4b', 'List three other security measures to prevent hacking.', 3,
    '["Biometric authentication. [1]","Access control. [1]","Antivirus software. [1]","Firewall. [1]","Two-factor/double authentication. [1]","Strong passwords. [1]","Intranet. [1]","1 mark per correct measure, up to max 3. Do NOT accept ''Backup'' or ''Encryption'' as a security measure here."]', null),
  ('p1_5a', 'Describe two features of open-source software.', 2,
    '["Generally free to use. [1]","The source code is free to modify. [1]","Does not offer extensive support. [1]","Enables technology agility. [1]","1 mark per correct feature, up to max 2."]', null),
  ('p1_5b', 'Explain the risks of using cloud technologies.', 2,
    '["Anyone with illegal access to the cloud can steal/delete/change/corrupt data. [1]","Absence of internet connection or technical server problems causes unavailability of data. [1]","Cloud service quality may be inadequate. [1]","Providers cannot guarantee no service disruptions will occur; data may not be available 24/7. [1]","1 mark per correct risk, up to max 2."]', null),
  ('p1_5c', 'Write ways to protect against cracking.', 2,
    '["Enact two-factor authentication. [1]","Increase password complexity. [1]","Use SSL protocol. [1]","Encrypting data. [1]","Hashing. [1]","Attend to login attempts. [1]","1 mark per correct way, up to max 2. Do NOT accept ''Backup'', ''Firewall'' or ''Antivirus''."]', null),
  ('p1_5d', 'Explain legal ways to use images from the Internet.', 2,
    '["Use public domain images. [1]","Use stock photos. [1]","Use social media images only with permission. [1]","Buy original works from an author. [1]","1 mark per correct way, up to max 2. Do NOT accept an answer only about linking to the image."]', null),
  ('p1_6a', 'Three software types — General-purpose software, Bespoke software, Special-purpose software — each match one of these descriptions: (1) It can only be used for one particular task. (2) It is off-the-shelf software that can be used for a variety of tasks. (3) It is developed to meet the user''s specific requirements. State which description matches each software type.', 2,
    '["General-purpose software matches: off-the-shelf software that can be used for a variety of tasks.","Bespoke software matches: developed to meet the user''s specific requirements.","Special-purpose software matches: can only be used for one particular task.","Award 1 mark if only one pairing is correct; award 2 marks if all three pairings are correct; award 0 marks if a description is matched to more than one software type."]', null),
  ('p1_6b', 'Explain two functions of an operating system.', 2,
    '["Provides an interface for computer interaction. [1]","Management of hardware and peripherals. [1]","Processor management for multitasking. [1]","Management and loading of software. [1]","Management of user accounts. [1]","Control of inputs and outputs. [1]","Memory management. [1]","Interrupt handling. [1]","Error handling. [1]","Security. [1]","1 mark per correct function, up to max 2."]', null),
  ('p1_6c', 'Give two features of the batch operating system.', 2,
    '["Jobs with similar requirements are batched together and run through the computer as a group. [1]","Data is collected for a defined period of time and processed as a pack of similar tasks. [1]","Sorting is performed before processing. [1]","Does not require user interaction. [1]","1 mark per correct feature, up to max 2."]', null),
  ('p1_7ai', 'Describe the purpose of the Arithmetic Logic Unit (ALU).', 1,
    '["ALU processes and manipulates data.","ALU carries out arithmetic (+, -, *, /) and logic (AND, OR, NOT, etc.) operations.","Accept any reasonable answer. Max 1 mark."]', null),
  ('p1_7aii', 'Describe the purpose of the Control Unit (CU).', 1,
    '["CU manages the execution of instructions / directs the operation of the processor.","CU tells memory, the ALU and I/O devices how to respond to instructions sent to the processor.","CU fetches instructions from main memory into the instruction register and acts on its contents.","CU generates control signals that supervise the execution of instructions.","Accept any reasonable answer. Max 1 mark."]', null),
  ('p1_7b', 'Describe the purposes of the data bus, the address bus and the control bus.', 3,
    '["Data bus: transfers data between the processor and memory / between components on the motherboard. [1]","Address bus: specifies a physical memory address so the data bus can access it / identifies the cache or main memory location to read from or write to. [1]","Control bus: carries control commands between the processor and other components / transmits the clock''s pulses. [1]","1 mark per correct bus description."]', null),
  ('p1_7c', 'Explain what happens at each step of the fetch-decode-execute cycle.', 3,
    '["Fetch: the CPU fetches the instruction/data from main memory (RAM), using the program counter, into a register. [1]","Decode: the CPU decodes/organises the instruction into its significant parts; the instruction in the CIR is interpreted and the control unit works out what it is. [1]","Execute: the instruction is executed, using the ALU if necessary; data processing takes place. [1]"]', null),
  ('p1_8a', 'Explain the purpose of virtual memory.', 2,
    '["Frees up space in RAM.","Increases the amount of memory available by working outside the limits of physical main memory.","Allows multiple tasks to execute at once on one CPU.","Swapping uses virtual memory to copy contents between primary (RAM) and secondary memory.","Improves system performance when using large programs.","1 mark per correct point, up to max 2."]', null),
  ('p1_8bi', 'Describe the process of segmentation.', 2,
    '["The main memory is logically divided into variable-size parts (segments).","Each segment has its own base address.","A segment table stores the base address and length of each segment.","1 mark per correct point, up to max 2."]', null),
  ('p1_8bii', 'Define the term memory address.', 1,
    '["A reference to a specific/unique memory location used by software and hardware.","A unique identifier used by a device or CPU for data tracking.","The location of where a variable is stored in memory.","Accept any one. Max 1 mark."]', null),
  ('p1_8biii', 'The program below uses two types of addressing modes: Line 1: LDA #5. Line 2: ADD 6. (Lines 5-8 hold the data values 6, 2, 10, 15.) State the addressing mode used in line 1 and in line 2.', 2,
    '["Line 1: Immediate addressing. [1]","Line 2: Indexed addressing. [1]"]', null),
  ('p1_9', 'Write two differences between declarative and imperative programming.', 2,
    '["Declarative programming focuses on what the program should perform; imperative focuses on how it should achieve the result. [1]","In declarative programming execution is not clearly delineated; imperative programming is made up of a clearly defined sequence of instructions. [1]","Functional/Logic/Query programming are declarative; Procedural and Object-Oriented programming are imperative. [1]","1 mark per correct difference, up to max 2."]', null),
  ('p1_10ai', 'Describe two advantages of using a compiled programming language over an interpreted one.', 2,
    '["Does not need to compile every time the program is executed. [1]","Creates an executable/object file. [1]","The whole code translates faster. [1]","1 mark per correct advantage, up to max 2."]', null),
  ('p1_10aii', 'Describe two advantages of using an interpreted programming language instead of a compiled one.', 2,
    '["Relatively easy to debug / finds and displays errors as each instruction is run. [1]","Takes less memory for translation. [1]","Each line of code is translated to machine code and executed at the same time. [1]","1 mark per correct advantage, up to max 2."]', null),
  ('p1_10bi', 'A compiler translates source code through these stages: Source code -> [A] -> Syntax analysis -> ... -> Code generation -> [B] -> Object file. Name and describe stage A.', 2,
    '["Name: Lexical analysis. [1]","Description: the process of parsing a stream of individual characters/strings and converting it into a sequence of lexical tokens (lexemes); lexical errors occur when a sequence of characters does not match the pattern of any token. [1]"]', null),
  ('p1_10bii', 'In the same compiler pipeline, name and describe stage B.', 2,
    '["Name: Code optimization. [1]","Description: improves the code so it consumes fewer resources and runs faster/increases execution speed. [1]"]', null),
  ('p1_11a', 'Explain the purpose of the IP address.', 2,
    '["A unique address of a device on the network. [1]","Used to send and receive data. [1]","Used for the identification and location of a network device. [1]","1 mark per correct point, up to max 2."]', null),
  ('p1_11b', 'Given the four octet values A=131, B=29, C=109, D=191, write them in the correct order to form a valid IP address.', 1,
    '["Correct order is D.A.C.B -> 191.131.109.29. [1 mark]"]', '191.131.109.29'),
  ('p1_11c', 'Name the OSI layer that uses the IP address.', 1,
    '["Network layer. [1 mark]"]', null),
  ('p1_11d', 'IP address 10.21.129.46 (binary 00001010.00010101.10000001.00101110) and subnet mask 255.255.248.0 (binary 11111111.11111111.11111000.00000000) are given. Determine the network address in denary, showing your working.', 3,
    '["Bitwise AND of IP and mask: 00001010.00010101.10000000.00000000. [1 mark for the bitwise AND]","Convert each octet to decimal: 10.21.128.0. [1 mark for the decimal conversion]","Network address: 10.21.128.0 (accept 10.21.128). [1 mark for the correct network address]"]',
    '00001010.00010101.10000001.00101110
AND 11111111.11111111.11111000.00000000
= 00001010.00010101.10000000.00000000
= 10.21.128.0'),
  ('p1_12a', 'Explain how the Client-Server model works.', 2,
    '["The client makes a request to a server (e.g. the browser requests the DNS server after the user enters a URL). [1]","The server responds to the client''s request and sends the necessary files; the DNS server responds with the IP address of the web server. [1]","1 mark per correct point, up to max 2."]', null),
  ('p1_12b', 'Provide two situations when the Client-Server model may be unstable.', 2,
    '["The server is located at a great distance from the client. [1]","The server receives a large number of requests. [1]","If a centralised server is damaged, the data stored on it may be lost. [1]","1 mark per correct situation, up to max 2."]', null),
  ('p1_12c', 'Explain two differences between packet switching and circuit switching.', 2,
    '["Circuit switching only needs sender/recipient addresses when establishing the connection; packet switching needs a sender and recipient address on every packet. [1]","Circuit switching delivers data in order over one dedicated channel; packet switching does not need a dedicated channel and packets can take different routes. [1]","Per the official mark scheme: circuit switching may lose some packets, while packet switching ensures packets reach their destination. [1]","1 mark per correctly explained difference, up to max 2."]', null),
  ('p1_12d', 'State the second-level domain name of the website www.sk.nis.edu.kz.', 1,
    '["edu. [1 mark]"]', null)
) as v(id, question, max_marks, points, model_answer)
on conflict (id) do update set
  assignment_id = excluded.assignment_id,
  question = excluded.question,
  max_marks = excluded.max_marks,
  points = excluded.points,
  model_answer = excluded.model_answer;
